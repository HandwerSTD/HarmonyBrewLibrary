import { HmAIError, HmAIErrorCode, asHmAIError } from '../core/Errors';
import { HmAIMessage, HmAIToolCall } from '../core/Message';
import { HmAIToolRegistry } from '../core/Tools';
import { HmAIChatModel, HmAIChatRequest, HmAIChatResult, HmAIStreamDelta,
  HmAIStreamObserver, HmAIStreamTask, HmAIToolResult } from '../core/Types';
import { HmAIAgentApprovalDecision, HmAIAgentApprovalPolicy, HmAIAgentObserver,
  HmAIAgentRepository, HmAIAgentStep, HmAIAgentStepState, HmAIAgentTask,
  HmAIAgentTaskState, HmAIAlwaysAskPolicy } from './AgentTypes';

export class HmAIAgentRuntimeOptions {
  maxRounds: number = 8;
  approvalPolicy: HmAIAgentApprovalPolicy = new HmAIAlwaysAskPolicy();
}

export class HmAIAgentRuntime {
  private readonly model: HmAIChatModel;
  private readonly tools: HmAIToolRegistry;
  private readonly repository?: HmAIAgentRepository;
  private readonly observer: HmAIAgentObserver;
  private readonly options: HmAIAgentRuntimeOptions;
  private activeTask?: HmAIStreamTask;
  private current?: HmAIAgentTask;
  private interrupted: boolean = false;

  constructor(model: HmAIChatModel, tools: HmAIToolRegistry, repository?: HmAIAgentRepository,
    observer: HmAIAgentObserver = new HmAIAgentObserver(),
    options: HmAIAgentRuntimeOptions = new HmAIAgentRuntimeOptions()) {
    if (options.maxRounds < 1 || options.maxRounds > 32) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'Agent maxRounds 必须在 1 到 32 之间');
    }
    this.model = model; this.tools = tools; this.repository = repository;
    this.observer = observer; this.options = options;
  }

  async start(input: string, initialMessages: HmAIMessage[] = []): Promise<HmAIAgentTask> {
    if (this.current !== undefined && this.current.state === HmAIAgentTaskState.RUNNING) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '已有 Agent 任务正在运行');
    }
    const prompt: string = input.trim();
    if (prompt.length === 0) throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'Agent 输入不能为空');
    const task: HmAIAgentTask = new HmAIAgentTask(prompt);
    task.messages = initialMessages.map((message: HmAIMessage): HmAIMessage => message.copy());
    task.messages.push(HmAIMessage.user(prompt));
    this.current = task; this.interrupted = false;
    return this.run(task);
  }

  async approve(taskId: string, stepId: string, decision: HmAIAgentApprovalDecision): Promise<HmAIAgentTask> {
    const task: HmAIAgentTask = await this.requireTask(taskId);
    const step: HmAIAgentStep | undefined = task.steps.find(
      (candidate: HmAIAgentStep): boolean => candidate.id === stepId);
    if (step === undefined || step.state !== HmAIAgentStepState.AWAITING_APPROVAL) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '找不到等待审批的 Agent 步骤');
    }
    if (decision === HmAIAgentApprovalDecision.DENY) {
      step.state = HmAIAgentStepState.DENIED; step.updatedAt = Date.now();
      task.messages.push(HmAIMessage.tool('工具调用已被用户拒绝', step.toolCall.id, step.toolCall.name));
    } else {
      step.state = HmAIAgentStepState.APPROVED; step.updatedAt = Date.now();
      await this.executeStep(task, step);
    }
    const pending: HmAIAgentStep | undefined = task.steps.find(
      (candidate: HmAIAgentStep): boolean => candidate.state === HmAIAgentStepState.AWAITING_APPROVAL);
    if (pending !== undefined) {
      task.state = HmAIAgentTaskState.AWAITING_APPROVAL;
      await this.persist(task); return task.copy();
    }
    this.current = task; this.interrupted = false;
    return this.run(task);
  }

  async resume(taskId: string): Promise<HmAIAgentTask> {
    const task: HmAIAgentTask = await this.requireTask(taskId);
    if (task.state === HmAIAgentTaskState.COMPLETED || task.state === HmAIAgentTaskState.CANCELLED) return task.copy();
    if (task.steps.some((step: HmAIAgentStep): boolean =>
      step.state === HmAIAgentStepState.AWAITING_APPROVAL)) {
      task.state = HmAIAgentTaskState.AWAITING_APPROVAL; return task.copy();
    }
    this.current = task; this.interrupted = false;
    return this.run(task);
  }

  interrupt(): void {
    this.interrupted = true;
    this.activeTask?.cancel();
  }

  async cancel(taskId: string): Promise<HmAIAgentTask> {
    const task: HmAIAgentTask = await this.requireTask(taskId);
    this.activeTask?.cancel();
    task.state = HmAIAgentTaskState.CANCELLED; task.updatedAt = Date.now();
    await this.persist(task); this.notify(task); return task.copy();
  }

  private async run(task: HmAIAgentTask): Promise<HmAIAgentTask> {
    while (task.round < this.options.maxRounds) {
      task.state = HmAIAgentTaskState.RUNNING; task.round++; task.updatedAt = Date.now();
      this.notify(task); await this.persist(task);
      const request: HmAIChatRequest = new HmAIChatRequest(task.messages);
      request.tools = this.tools.getDefinitions();
      let streamed: string = '';
      this.activeTask = this.model.createStream(request, new HmAIStreamObserver(
        (delta: HmAIStreamDelta): void => { streamed += delta.content; this.observer.onTextDelta(delta.content); }
      ));
      try {
        const result: HmAIChatResult = await this.activeTask.start();
        this.activeTask = undefined;
        task.messages.push(HmAIMessage.assistant(result.content, result.toolCalls));
        task.response = result.content.length > 0 ? result.content : streamed;
        if (result.toolCalls.length === 0) {
          task.state = HmAIAgentTaskState.COMPLETED; task.updatedAt = Date.now();
          await this.persist(task); this.notify(task); return task.copy();
        }
        const needsApproval: boolean = await this.prepareToolSteps(task, result.toolCalls);
        if (needsApproval) {
          task.state = HmAIAgentTaskState.AWAITING_APPROVAL; task.updatedAt = Date.now();
          await this.persist(task); this.notify(task); return task.copy();
        }
      } catch (error) {
        this.activeTask = undefined;
        if (this.interrupted) {
          task.state = HmAIAgentTaskState.PAUSED; task.updatedAt = Date.now();
          await this.persist(task); this.notify(task); return task.copy();
        }
        const mapped: HmAIError = error instanceof Error ? asHmAIError(error) :
          new HmAIError(HmAIErrorCode.INTERNAL, 'Agent 执行失败');
        task.state = HmAIAgentTaskState.FAILED; task.error = mapped.message; task.updatedAt = Date.now();
        await this.persist(task); this.notify(task); throw mapped;
      }
    }
    const limit: HmAIError = new HmAIError(HmAIErrorCode.TOOL_ROUND_LIMIT, 'Agent 超过最大执行轮次');
    task.state = HmAIAgentTaskState.FAILED; task.error = limit.message; task.updatedAt = Date.now();
    await this.persist(task); this.notify(task); throw limit;
  }

  private async prepareToolSteps(task: HmAIAgentTask, calls: HmAIToolCall[]): Promise<boolean> {
    let needsApproval: boolean = false;
    for (let index: number = 0; index < calls.length; index++) {
      const call: HmAIToolCall = calls[index];
      const step: HmAIAgentStep = new HmAIAgentStep(`${task.id}_step_${task.steps.length + 1}`, call);
      task.steps.push(step);
      if (this.options.approvalPolicy.requiresApproval(call)) {
        step.state = HmAIAgentStepState.AWAITING_APPROVAL; needsApproval = true;
      } else {
        await this.executeStep(task, step);
      }
    }
    return needsApproval;
  }

  private async executeStep(task: HmAIAgentTask, step: HmAIAgentStep): Promise<void> {
    step.state = HmAIAgentStepState.RUNNING; step.updatedAt = Date.now(); this.notify(task);
    try {
      const result: HmAIToolResult = await this.tools.execute(step.toolCall);
      step.output = result.content; step.state = HmAIAgentStepState.COMPLETED; step.updatedAt = Date.now();
      task.messages.push(HmAIMessage.tool(result.content, result.toolCallId, result.name));
    } catch (error) {
      const mapped: HmAIError = error instanceof Error ? asHmAIError(error, 'Agent 工具执行失败') :
        new HmAIError(HmAIErrorCode.TOOL, 'Agent 工具执行失败');
      step.error = mapped.message; step.state = HmAIAgentStepState.FAILED; step.updatedAt = Date.now();
      throw mapped;
    }
  }

  private async requireTask(id: string): Promise<HmAIAgentTask> {
    if (this.current?.id === id) return this.current;
    const loaded: HmAIAgentTask | undefined = await this.repository?.load(id);
    if (loaded === undefined) throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, `找不到 Agent 任务：${id}`);
    return loaded;
  }
  private async persist(task: HmAIAgentTask): Promise<void> { await this.repository?.save(task.copy()); }
  private notify(task: HmAIAgentTask): void { this.observer.onTaskChange(task.copy()); }
}
