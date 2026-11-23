import { fileIo as fs } from '@kit.CoreFileKit';
import { HmAIAgentRepository, HmAIAgentStep, HmAIAgentStepState,
  HmAIAgentTask, HmAIAgentTaskState } from '../agent/AgentTypes';
import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { HmAIToolCall } from '../core/Message';
import { HmAIMessageCodec } from './MessageCodec';

class AgentStepWire {
  id: string = '';
  toolCallId: string = '';
  toolName: string = '';
  argumentsJson: string = '';
  toolIndex: number = 0;
  state: HmAIAgentStepState = HmAIAgentStepState.PENDING;
  output: string = '';
  error: string = '';
  createdAt: number = 0;
  updatedAt: number = 0;

  static fromStep(step: HmAIAgentStep): AgentStepWire {
    const wire: AgentStepWire = new AgentStepWire();
    wire.id = step.id; wire.toolCallId = step.toolCall.id; wire.toolName = step.toolCall.name;
    wire.argumentsJson = step.toolCall.argumentsJson; wire.toolIndex = step.toolCall.index;
    wire.state = step.state; wire.output = step.output; wire.error = step.error;
    wire.createdAt = step.createdAt; wire.updatedAt = step.updatedAt; return wire;
  }
  static toStep(wire: AgentStepWire): HmAIAgentStep {
    const step: HmAIAgentStep = new HmAIAgentStep(wire.id,
      new HmAIToolCall(wire.toolCallId, wire.toolName, wire.argumentsJson, wire.toolIndex), wire.state, wire.createdAt);
    step.output = wire.output; step.error = wire.error; step.updatedAt = wire.updatedAt; return step;
  }
}

class AgentTaskWire {
  id: string = '';
  input: string = '';
  state: HmAIAgentTaskState = HmAIAgentTaskState.PENDING;
  messagesJson: string = '[]';
  steps: AgentStepWire[] = [];
  response: string = '';
  error: string = '';
  round: number = 0;
  createdAt: number = 0;
  updatedAt: number = 0;

  static fromTask(task: HmAIAgentTask): AgentTaskWire {
    const wire: AgentTaskWire = new AgentTaskWire();
    wire.id = task.id; wire.input = task.input; wire.state = task.state;
    wire.messagesJson = HmAIMessageCodec.encode(task.messages);
    wire.steps = task.steps.map((step: HmAIAgentStep): AgentStepWire => AgentStepWire.fromStep(step));
    wire.response = task.response; wire.error = task.error; wire.round = task.round;
    wire.createdAt = task.createdAt; wire.updatedAt = task.updatedAt; return wire;
  }
  static toTask(wire: AgentTaskWire): HmAIAgentTask {
    const task: HmAIAgentTask = new HmAIAgentTask(wire.input, wire.id, wire.createdAt);
    task.state = wire.state; task.messages = HmAIMessageCodec.decode(wire.messagesJson);
    task.steps = (wire.steps ?? []).map((step: AgentStepWire): HmAIAgentStep => AgentStepWire.toStep(step));
    task.response = wire.response; task.error = wire.error; task.round = wire.round; task.updatedAt = wire.updatedAt;
    return task;
  }
}

export class HmAIMemoryAgentRepository implements HmAIAgentRepository {
  protected tasks: HmAIAgentTask[] = [];
  async save(task: HmAIAgentTask): Promise<void> {
    this.tasks = this.tasks.filter((item: HmAIAgentTask): boolean => item.id !== task.id); this.tasks.push(task.copy());
  }
  async load(id: string): Promise<HmAIAgentTask | undefined> {
    return this.tasks.find((task: HmAIAgentTask): boolean => task.id === id)?.copy();
  }
  async list(): Promise<HmAIAgentTask[]> {
    return [...this.tasks].sort((left: HmAIAgentTask, right: HmAIAgentTask): number =>
      right.updatedAt - left.updatedAt).map((task: HmAIAgentTask): HmAIAgentTask => task.copy());
  }
  async delete(id: string): Promise<void> {
    this.tasks = this.tasks.filter((task: HmAIAgentTask): boolean => task.id !== id);
  }
}

export class HmAIFileAgentRepository extends HmAIMemoryAgentRepository {
  private readonly filePath: string;
  private loaded: boolean = false;
  constructor(directory: string, fileName: string = 'hmkit-ai-agent-tasks.json') {
    super();
    if (directory.trim().length === 0) throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '存储目录不能为空');
    this.filePath = `${directory.endsWith('/') ? directory.slice(0, -1) : directory}/${fileName}`;
  }
  async save(task: HmAIAgentTask): Promise<void> { await this.ensureLoaded(); await super.save(task); this.flush(); }
  async load(id: string): Promise<HmAIAgentTask | undefined> { await this.ensureLoaded(); return super.load(id); }
  async list(): Promise<HmAIAgentTask[]> { await this.ensureLoaded(); return super.list(); }
  async delete(id: string): Promise<void> { await this.ensureLoaded(); await super.delete(id); this.flush(); }
  private async ensureLoaded(): Promise<void> {
    if (this.loaded) return; this.loaded = true;
    try {
      if (!fs.accessSync(this.filePath)) return;
      const wires: AgentTaskWire[] = JSON.parse(fs.readTextSync(this.filePath)) as AgentTaskWire[];
      this.tasks = wires.map((wire: AgentTaskWire): HmAIAgentTask => AgentTaskWire.toTask(wire));
    } catch (error) {
      throw new HmAIError(HmAIErrorCode.INTERNAL,
        error instanceof Error ? `无法读取 Agent 存储：${error.message}` : '无法读取 Agent 存储');
    }
  }
  private flush(): void {
    const wires: AgentTaskWire[] = this.tasks.map((task: HmAIAgentTask): AgentTaskWire => AgentTaskWire.fromTask(task));
    let file: fs.File | undefined;
    try {
      file = fs.openSync(this.filePath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(wires));
    } catch (error) {
      throw new HmAIError(HmAIErrorCode.INTERNAL,
        error instanceof Error ? `无法写入 Agent 存储：${error.message}` : '无法写入 Agent 存储');
    } finally {
      if (file !== undefined) { try { fs.closeSync(file); } catch (_error) {} }
    }
  }
}
