/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

// ---------------------------------------------------------------- 执行通道

export { ShellUtils } from './src/main/ets/util/ShellUtils';
export { ShellProbe, ShellProbeReport } from './src/main/ets/util/ShellProbe';

export {
  SHELL_BREW_PATH_CANDIDATES,
  SHELL_ERR_EXIT,
  SHELL_ERR_NONE,
  SHELL_ERR_OUTPUT_LIMIT,
  SHELL_ERR_START,
  SHELL_ERR_TIMEOUT,
  SHELL_ERR_UNAVAILABLE,
  SHELL_OUTPUT_LIMIT_BYTES,
  SHELL_TIMEOUT_DEFAULT_MS,
  SHELL_TIMEOUT_MAX_MS,
  SHELL_VERIFY,
  ShellProbeCase,
  ShellResult,
} from './src/main/ets/constant/ShellConstants';
