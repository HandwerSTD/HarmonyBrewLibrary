/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

// ---------------------------------------------------------------- 执行通道

export { ShellUtils } from './src/main/ets/util/ShellUtils';

export { ShellStreamProbe } from './src/main/ets/util/ShellStreamProbe';

export {
  SHELL_BREW_PATH_CANDIDATES,
  SHELL_DEFAULT_WORKING_DIRECTORY,
  SHELL_ERR_EXIT,
  SHELL_ERR_INTERRUPTED,
  SHELL_ERR_NONE,
  SHELL_ERR_OUTPUT_LIMIT,
  SHELL_ERR_START,
  SHELL_ERR_TIMEOUT,
  SHELL_ERR_UNAVAILABLE,
  SHELL_OUTPUT_LIMIT_BYTES,
  SHELL_STREAM_POLL_MAX_BYTES,
  SHELL_STREAM_VERIFY,
  SHELL_TIMEOUT_DEFAULT_MS,
  SHELL_TIMEOUT_MAX_MS,
  ShellResult,
  ShellStreamEvent,
  ShellStreamPoll,
} from './src/main/ets/constant/ShellConstants';
