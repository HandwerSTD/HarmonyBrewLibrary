import { HmAIMessage, HmAIToolCall } from '../core/Message';

let nextAgentId: number = 0;

export enum HmAIAgentTaskState {
  PENDING = 'pending',
  RUNNING = 'running',
  AWAITING_APPROVAL = 'awaiting_approval',
  PAUSED = 'paused',
  COMPLETED = 'completed',
  FAILED = 'failed',
  CANCELLED = 'cancelled'
}

export enum HmAIAgentStepState {
  PENDING = 'pending',
  RUNNING = 'running',
  AWAITING_APPROVAL = 'awaiting_approval',
  APPROVED = 'approved',
  DENIED = 'denied',
  COMPLETED = 'completed',
  FAILED = 'failed'
}

export enum HmAIAgentApprovalDecision {
  APPROVE = 'approve',
  DENY = 'deny'
}

export class HmAIAgentStep {
  readonly id: string;
  readonly toolCall: HmAIToolCall;
  state: HmAIAgentStepState;
  output: string = '';
  error: string = '';
  readonly createdAt: number;
  updatedAt: number;

  constructor(id: string, toolCall: HmAIToolCall,
    state: HmAIAgentStepState = HmAIAgentStepState.PENDING, createdAt: number = Date.now()) {
    this.id = id;
    this.toolCall = toolCall.copy();
    this.state = state;
    this.createdAt = createdAt;
    this.updatedAt = createdAt;
  }

  copy(): HmAIAgentStep {
    const step: HmAIAgentStep = new HmAIAgentStep(this.id, this.toolCall, this.state, this.createdAt);
    step.output = this.output; step.error = this.error; step.updatedAt = this.updatedAt;
    return step;
  }
}

export class HmAIAgentTask {
  readonly id: string;
  readonly input: string;
  state: HmAIAgentTaskState = HmAIAgentTaskState.PENDING;
  messages: HmAIMessage[] = [];
  steps: HmAIAgentStep[] = [];
  response: string = '';
  error: string = '';
  round: number = 0;
  readonly createdAt: number;
  updatedAt: number;

  constructor(input: string, id: string = '', createdAt: number = Date.now()) {
    nextAgentId++;
    this.id = id.length > 0 ? id : `hm_agent_${createdAt}_${nextAgentId}`;
    this.input = input;
    this.createdAt = createdAt;
    this.updatedAt = createdAt;
  }

  copy(): HmAIAgentTask {
    const task: HmAIAgentTask = new HmAIAgentTask(this.input, this.id, this.createdAt);
    task.state = this.state;
    task.messages = this.messages.map((message: HmAIMessage): HmAIMessage => message.copy());
    task.steps = this.steps.map((step: HmAIAgentStep): HmAIAgentStep => step.copy());
    task.response = this.response; task.error = this.error; task.round = this.round; task.updatedAt = this.updatedAt;
    return task;
  }
}

export interface HmAIAgentRepository {
  save(task: HmAIAgentTask): Promise<void>;
  load(id: string): Promise<HmAIAgentTask | undefined>;
  list(): Promise<HmAIAgentTask[]>;
  delete(id: string): Promise<void>;
}

export interface HmAIAgentApprovalPolicy {
  requiresApproval(call: HmAIToolCall): boolean;
}

export class HmAIAlwaysApprovePolicy implements HmAIAgentApprovalPolicy {
  requiresApproval(_call: HmAIToolCall): boolean { return false; }
}

export class HmAIAlwaysAskPolicy implements HmAIAgentApprovalPolicy {
  requiresApproval(_call: HmAIToolCall): boolean { return true; }
}

export class HmAINamedApprovalPolicy implements HmAIAgentApprovalPolicy {
  private readonly protectedTools: string[];
  constructor(protectedTools: string[]) { this.protectedTools = protectedTools; }
  requiresApproval(call: HmAIToolCall): boolean { return this.protectedTools.includes(call.name); }
}

export class HmAIAgentObserver {
  readonly onTaskChange: (task: HmAIAgentTask) => void;
  readonly onTextDelta: (delta: string) => void;
  constructor(onTaskChange: (task: HmAIAgentTask) => void = (_task: HmAIAgentTask): void => {},
    onTextDelta: (delta: string) => void = (_delta: string): void => {}) {
    this.onTaskChange = onTaskChange; this.onTextDelta = onTextDelta;
  }
}
