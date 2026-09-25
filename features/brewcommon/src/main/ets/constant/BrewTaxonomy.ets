/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { BrewKind } from '../model/BrewModels';

/**
 * 分类体系：**策展覆盖 + 关键词 + 主题词**三层词表的设备端移植。
 *
 * **本文件由 `hmosword-build/brew-mockgen/gen_taxonomy.py` 生成，不要手改** ——
 * 改词表请改 `lexicon.json` / `tokens.json`，然后跑：
 *   `python3 gen_taxonomy.py && python3 gen_taxonomy.py --check`
 * 生成器与 `generate.py`（生成期参考实现）共用同一份口径，`eval_lexicon.py` 用它在现网全量上量兜底率。
 *
 * 为什么需要它：官方 API **没有任何分类字段** —— 分类一直是自建词表算出来的。
 * 以前这套词表只在构建期跑一次，结果落进 `brew-{formula,cask}-page.json`；
 * 现在目录（全量 1.6 万 token）已经在设备端了，分类也必须在设备端算，否则"能浏览的包"
 * 永远被那 240 个内置条目锁死。
 *
 * 判别顺序（与 `generate.py` 一致）：
 *   1. **策展覆盖**（`tokens.json`）：命中就直接用 —— 这两百多个包是人工确定过分类的；
 *   2. **关键词**（`lexicon.json` 的 `<kind>`）：desc 前 3 个词命中记 3 分、其余位置 1 分，
 *      最高分 ≥ `minScore` 且领先第二名 ≥ `minMargin` 才算命中；
 *   3. **主题词**（`lexicon.json` 的 `_subjects`）：关键词判不出来时，用「中心名词/主语」再查一次表
 *      （`kubernetes` 这类词本身足以判别，所以单词命中即定、不再算分）；
 *   4. **形态兜底桶**（`lexicon.json` 的 `_forms`）：前三层都不中、而描述形态上就是「库/框架/SDK」的，
 *      归到 `lib`（formula）。**不参与打分**，所以不会抢走已有分类；
 *   5. 都不中 → 归到该 kind 的**兜底分类**（formula `system` / cask `systemtool`）。
 *
 * 第 3 层是量出来的（`lexicon-eval.md`）：只加主题词就把 formula 的兜底率从 70.6% 降到 56.7%，
 * 而关键词层**0 条翻转**（它只在关键词层判不出来时生效，因此不可能改坏已有分类）。
 *
 * 分类的英文名与图标不在本文件：UI 侧已经按 categoryKey 自己查
 * （`FORMULA_CATEGORY_NAME` / `getCategorySymbolMap`），键位对齐 `categories.json` 即可。
 */

/**
 * 主题词的抽取规则（与 `generate.py: subject_terms()` 逐行对应）：
 * 从「desc 头部 2/3-gram、`for <...>`、`<X> library`」三处取候选，返回**按优先级排好**的列表，
 * 调用方取第一个命中的。
 *
 * 形态词紧前面那个词常常是泛化词（`Audio File Library` 里的 `file`），拿它查表会把包归错类
 * （实测：`C++ Audio File Library` 被 `file` 判成 system），所以遇到泛化词要往左继续找。
 */
const SUBJECT_GENERIC: Set<string> = new Set<string>([
  'file', 'files', 'data', 'string', 'strings', 'text', 'tool', 'tools', 'utility', 'utilities',
  'collection', 'set', 'input', 'output', 'process', 'system', 'resource', 'resources', 'client',
  'server', 'wrapper', 'module', 'things', 'stuff', 'general', 'purpose', 'fast', 'simple', 'small',
  'library', 'libraries', 'cross', 'platform', 'command', 'line', 'package', 'program', 'programs',
]);

const SUBJECT_WORD_RE: RegExp = /[a-z0-9]+/g;
const SUBJECT_FOR_RE: RegExp = /\bfor\s+([a-z0-9][a-z0-9 +.#/_-]{2,48})/;
const SUBJECT_FORM_RE: RegExp =
  /(?:^|[^a-z0-9])((?:[a-z0-9][a-z0-9+.#_-]*\s+){0,2})([a-z0-9][a-z0-9+.#_-]*)\s+(?:library|framework|sdk|toolkit|bindings?|implementation|port)\b/;

function subjectWords(text: string): string[] {
  return text.match(SUBJECT_WORD_RE) ?? [];
}

function subjectTerms(desc: string): string[] {
  const text: string = (desc ?? '').toLowerCase();
  const words: string[] = subjectWords(text);
  const terms: string[] = [];
  if (words.length >= 3) {
    terms.push(words.slice(0, 3).join(' '));
  }
  if (words.length >= 2) {
    terms.push(words.slice(0, 2).join(' '));
  }
  const forMatch: RegExpMatchArray | null = text.match(SUBJECT_FOR_RE);
  if (forMatch !== null) {
    const sub: string[] = subjectWords(forMatch[1] ?? '');
    terms.push(sub.slice(0, 2).join(' '));
    sub.slice(0, 2).forEach((word: string) => terms.push(word));
  }
  const formMatch: RegExpMatchArray | null = text.match(SUBJECT_FORM_RE);
  if (formMatch !== null) {
    const before: string[] = subjectWords(formMatch[1] ?? '');
    if (before.length > 0) {
      terms.push(before.slice(-2).join(' '));
    }
    for (let i = before.length - 1; i >= 0; i--) {
      if (!SUBJECT_GENERIC.has(before[i])) {
        terms.push(before[i]);
        break;
      }
    }
    before.forEach((word: string) => terms.push(word));
    terms.push(formMatch[2] ?? '');
  }
  const out: string[] = [];
  terms.forEach((term: string) => {
    if (term.length > 0 && out.indexOf(term) < 0) {
      out.push(term);
    }
  });
  return out;
}

/** 关键词判定的阈值（`lexicon.json` 的 `_threshold`） */
export interface BrewLexiconThreshold {
  minScore: number;
  minMargin: number;
}

export const BREW_LEXICON_THRESHOLD: BrewLexiconThreshold = { minScore: 2, minMargin: 2 };

/** 关键词层：`<kind>:<categoryKey>` -> 关键词数组（判别性强的在前，与 JSON 顺序一致） */
function buildLexicon(): Map<string, string[]> {
  const lexicon: Map<string, string[]> = new Map<string, string[]>();
  lexicon.set('formula:terminal', ['shell', 'prompt', 'completion', 'multiplexer', 'fuzzy finder', 'pager', 'syntax highlighting', 'terminal', 'history', 'zsh', 'fish', 'bash', 'tmux', 'direnv', 'command-line', 'cli']);
  lexicon.set('formula:devtools', ['compiler', 'toolchain', 'version manager', 'sdk', 'jdk', 'build system', 'linter', 'formatter', 'package manager', 'version control', 'vcs', 'language', 'runtime', 'debugger', 'git', 'cargo']);
  lexicon.set('formula:network', ['download', 'http', 'https', 'proxy', 'ssh', 'ftp', 'torrent', 'dns', 'traceroute', 'port scanner', 'bandwidth', 'network', 'socket', 'web server', 'curl']);
  lexicon.set('formula:data', ['database', 'sql', 'key-value', 'cache', 'query', 'etl', 'json processor', 'yaml', 'csv', 'postgres', 'mysql', 'redis', 'columnar', 'storage engine']);
  lexicon.set('formula:cloudnative', ['kubernetes', 'container', 'helm', 'cluster', 'cloud', 'terraform', 'infrastructure as code', 'serverless', 'orchestration', 'docker', 'k8s']);
  lexicon.set('formula:media', ['image', 'video', 'audio', 'codec', 'encode', 'transcode', 'resize', 'subtitle', 'ocr', 'metadata', 'compression', 'graphics', 'ffmpeg']);
  lexicon.set('formula:ai', ['machine learning', 'neural', 'large language model', 'inference', 'embedding', 'vector', 'gpu', 'model', 'ai', 'tensor', 'diffusion', 'speech']);
  lexicon.set('formula:system', ['system monitor', 'disk usage', 'backup', 'benchmark', 'performance', 'monitoring', 'encryption', 'cleanup', 'process', 'file', 'resource', 'grep', 'search']);
  lexicon.set('cask:devide', ['ide', 'editor', 'code', 'development', 'programming', 'api', 'database client', 'git', 'debug', 'terminal emulator', 'text editor', 'code editor', 'terminal', 'api client', 'http client', 'diff', 'merge', 'hex editor', 'json viewer', 'developer', 'developers', 'devops', 'sdk', 'compiler', 'interpreter', 'source code']);
  lexicon.set('cask:browser', ['browser', 'web browser', 'chromium', 'firefox', 'web', 'tor browser', 'browser extension']);
  lexicon.set('cask:productivity', ['productivity', 'note', 'notes', 'task', 'calendar', 'to-do', 'launcher', 'window', 'clipboard', 'reminder', 'markdown', 'password manager', 'spreadsheet', 'office suite', 'pdf reader', 'mind map', 'time tracking', 'finance', 'ebook', 'dictionary', 'translation', 'presentation', 'window manager', 'clipboard manager', 'task manager', 'note-taking']);
  lexicon.set('cask:comm', ['chat', 'messaging', 'video call', 'meeting', 'email', 'communication', 'collaboration', 'team', 'email client', 'mail client', 'vpn', 'vpn client', 'remote desktop', 'file sharing', 'file transfer', 'irc', 'rss', 'news reader', 'screen sharing', 'voip', 'instant messaging']);
  lexicon.set('cask:design', ['design', 'graphics', 'drawing', 'photo', 'vector', '3d', 'painting', 'illustration', 'ui', 'mockup', 'image editor', 'photo editor', '3d modeling', 'cad', 'font manager', 'color picker', 'diagram', 'flowchart', 'animation', 'wireframe', 'ui design', 'graphics editor']);
  lexicon.set('cask:av', ['player', 'media player', 'video', 'audio', 'music', 'recording', 'streaming', 'screen', 'podcast', 'convert', 'video player', 'music player', 'audio editor', 'screen recorder', 'screen capture', 'daw', 'equalizer', 'synthesizer', 'dj']);
  lexicon.set('cask:systemtool', ['utility', 'cleaner', 'uninstaller', 'monitor', 'disk', 'archive', 'system', 'menu bar', 'usb', 'image writer', 'battery', 'quick look', 'quick look plugin', 'status bar', 'screensaver', 'wallpaper', 'dock', 'spotlight', 'file manager', 'disk utility', 'cloud storage', 'backup', 'keyboard', 'mouse', 'trackpad', 'driver', 'firmware', 'printer', 'temperature', 'fan control', 'maintenance', 'system utility', 'utilities']);
  lexicon.set('cask:aivm', ['virtual machine', 'vm', 'container', 'emulator', 'assistant', 'ai', 'language model', 'chatbot', 'desktop', 'local model', 'ai assistant', 'machine learning', 'gpu', 'containerization']);
  return lexicon;
}
/** 主题词层：`<kind>:<主题词>` -> categoryKey（表在 JSON 里按「分类 -> 词」维护，这里展开成反查表） */
function buildSubjects(): Map<string, string> {
  const subjects: Map<string, string> = new Map<string, string>();
  const table: Record<string, Record<string, string[]>> = {
    'formula': {
      'terminal': ['command line', 'command line tool', 'command line interface', 'command-line tool', 'cli tool', 'shell', 'terminal', 'tui', 'prompt', 'completion', 'pager', 'syntax highlighting', 'multiplexer', 'man page', 'dotfiles', 'vim', 'neovim', 'emacs', 'zsh', 'bash', 'fish', 'tmux', 'less'],
      'devtools': ['c', 'c++', 'objective-c', 'rust', 'go', 'golang', 'python', 'ruby', 'java', 'javascript', 'typescript', 'node', 'nodejs', 'haskell', 'ocaml', 'lua', 'php', 'perl', 'swift', 'kotlin', 'scala', 'clojure', 'erlang', 'elixir', 'dart', 'zig', 'nim', 'crystal', 'fortran', 'assembly', 'programming language', 'compiler', 'interpreter', 'interpreters', 'parser', 'parser generator', 'linter', 'linting', 'testing', 'test framework', 'unit testing', 'fuzzing', 'build', 'build tool', 'build system', 'code generation', 'code generator', 'documentation', 'docs', 'language server', 'debugger', 'profiler', 'static analysis', 'formatter', 'formatting', 'package manager', 'version manager', 'dependency manager', 'sdk', 'toolchain', 'assembler', 'regex', 'make', 'cmake', 'gradle', 'maven', 'bazel', 'git', 'github', 'gitlab', 'version control', 'diff', 'patch'],
      'network': ['http', 'https', 'http2', 'http client', 'http server', 'web server', 'proxy', 'ssh', 'sftp', 'ftp', 'tls', 'ssl', 'openssl', 'dns', 'smtp', 'imap', 'pop3', 'email', 'mail', 'socket', 'tcp', 'udp', 'url', 'uri', 'network', 'networking', 'download', 'downloader', 'downloading', 'torrent', 'bittorrent', 'vpn', 'wireguard', 'ipfs', 'websocket', 'rest', 'grpc', 'ping', 'traceroute', 'port scanner', 'bandwidth', 'speed test', 'wget', 'curl', 'webhook', 'webhooks', 'api client', 'api server'],
      'data': ['database', 'databases', 'sql', 'sqlite', 'postgres', 'postgresql', 'mysql', 'mariadb', 'redis', 'mongodb', 'cassandra', 'elasticsearch', 'clickhouse', 'duckdb', 'json', 'yaml', 'toml', 'xml', 'csv', 'tsv', 'data', 'datasets', 'dataset', 'serialization', 'deserialization', 'compression', 'compressor', 'decompression', 'archive', 'archives', 'key-value', 'caching', 'cache', 'columnar', 'parquet', 'analytics', 'statistics', 'etl', 'query', 'queries', 'schema', 'migration', 'search engine', 'full-text search', 'indexing', 'data processing', 'data structures'],
      'cloudnative': ['kubernetes', 'k8s', 'docker', 'container', 'containers', 'containerization', 'helm', 'cluster', 'clusters', 'cloud', 'aws', 'amazon web services', 'azure', 'gcp', 'google cloud', 'terraform', 'pulumi', 'infrastructure as code', 'serverless', 'lambda', 'orchestration', 'service mesh', 'istio', 'prometheus', 'grafana', 'observability', 'ci/cd', 'cicd', 'continuous integration', 'devops', 'nomad', 'consul', 'vault', 's3', 'object storage', 'microservices'],
      'media': ['image', 'images', 'image processing', 'video', 'video processing', 'audio', 'sound', 'sound files', 'music', 'graphics', 'font', 'fonts', 'typography', 'pdf', 'png', 'jpeg', 'jpg', 'gif', 'svg', 'webp', 'avif', 'heic', 'bmp', 'tiff', 'codec', 'encoding', 'decoding', 'transcode', 'transcoding', 'ocr', 'subtitle', 'subtitles', 'media', 'camera', 'color', 'colour', 'photo', 'screenshot', 'animation', 'signal processing', 'ffmpeg', 'vorbis', 'opus', 'flac', 'mp3', 'exif', 'metadata', 'image manipulation', 'audio processing', 'video encoding', 'image conversion'],
      'ai': ['machine learning', 'deep learning', 'neural', 'neural network', 'neural networks', 'llm', 'llms', 'large language model', 'language model', 'language models', 'embedding', 'embeddings', 'tensor', 'tensors', 'gpu', 'cuda', 'inference', 'model', 'models', 'transformer', 'transformers', 'diffusion', 'speech', 'speech recognition', 'text to speech', 'tokenizer', 'vector', 'vectors', 'ai', 'artificial intelligence', 'chatbot', 'computer vision', 'object detection', 'onnx', 'pytorch', 'tensorflow', 'whisper', 'reinforcement learning'],
      'system': ['system monitor', 'monitoring', 'disk usage', 'disk', 'disks', 'filesystem', 'file system', 'backup', 'backups', 'benchmark', 'benchmarking', 'performance', 'profiling', 'encryption', 'encrypt', 'decrypt', 'gpg', 'cleanup', 'cleaner', 'process', 'processes', 'resource', 'resources', 'file', 'files', 'file management', 'coreutils', 'system information', 'hardware', 'cpu', 'memory', 'temperature', 'sensors', 'keyboard', 'input', 'clipboard', 'search', 'find', 'grep', 'sed', 'awk', 'text processing', 'system utilities', 'system administration', 'diagnostics'],
    },
    'cask': {
      'devide': ['ide', 'code editor', 'text editor', 'source code editor', 'api client', 'database client', 'sql client', 'git client', 'diff tool', 'merge tool', 'hex editor', 'json viewer', 'regex', 'debugger', 'emulator', 'simulator', 'android', 'ios', 'unity', 'game engine', 'developer', 'developers', 'development', 'programming', 'coding', 'terminal', 'terminal emulator', 'sftp client', 'ftp client', 'ssh client', 'cli', 'command line', 'devops', 'software development', 'code', 'api'],
      'browser': ['browser', 'web browser', 'web browsers', 'tor', 'browser extension', 'web'],
      'productivity': ['password manager', 'notes', 'note taking', 'note-taking', 'task manager', 'to-do', 'todo', 'calendar', 'spreadsheet', 'office', 'document', 'documents', 'pdf reader', 'markdown editor', 'mind map', 'time tracking', 'launcher', 'clipboard manager', 'window manager', 'window management', 'focus', 'finance', 'budget', 'ebook', 'translation', 'dictionary', 'presentation', 'organization'],
      'comm': ['email', 'email client', 'mail', 'chat', 'messaging', 'instant messaging', 'video call', 'video conferencing', 'meeting', 'voip', 'vpn', 'vpn client', 'remote desktop', 'file sharing', 'file transfer', 'irc', 'matrix', 'mastodon', 'bluesky', 'social', 'rss', 'news reader', 'team communication', 'screen sharing'],
      'design': ['image editor', 'photo editor', 'vector graphics', 'drawing', 'painting', '3d', '3d modeling', 'cad', 'animation', 'font manager', 'color picker', 'mockup', 'wireframe', 'icon', 'ui design', 'diagram', 'flowchart', 'graphics editor', 'design tool', 'photo', 'graphics', 'design'],
      'av': ['media player', 'video player', 'music player', 'audio', 'audio editor', 'audio player', 'video', 'player', 'music', 'podcast', 'streaming', 'screen recorder', 'screen capture', 'subtitle', 'transcode', 'equalizer', 'daw', 'dj', 'recording', 'synthesizer', 'media'],
      'systemtool': ['quick look', 'quick look plugin', 'menu bar', 'menu bar application', 'menu bar app', 'status bar', 'screensaver', 'wallpaper', 'dock', 'spotlight', 'uninstaller', 'cleaner', 'disk utility', 'file manager', 'backup', 'cloud storage', 'monitor', 'system monitor', 'battery', 'temperature', 'fan control', 'keyboard', 'mouse', 'trackpad', 'driver', 'firmware', 'printer', 'scanner', 'usb', 'image writer', 'archive', 'encryption', 'system', 'utility', 'utilities', 'system utility', 'maintenance'],
      'aivm': ['virtual machine', 'vm', 'container', 'containerization', 'ai assistant', 'chatbot', 'llm', 'local model', 'language model', 'ai', 'artificial intelligence', 'desktop', 'assistant', 'gpu', 'machine learning'],
    },
  };
  Object.keys(table).forEach((kind: string) => {
    const byCategory: Record<string, string[]> = table[kind];
    Object.keys(byCategory).forEach((categoryKey: string) => {
      byCategory[categoryKey].forEach((term: string) => subjects.set(`${kind}:${term}`, categoryKey));
    });
  });
  return subjects;
}
/** 形态兜底桶：`<kind>:<分类>` -> 形态词（表在 JSON 里按「分类 -> 词」维护，这里展开成反查表） */
function buildForms(): Map<string, string> {
  const forms: Map<string, string> = new Map<string, string>();
  const table: Record<string, Record<string, string[]>> = {
    'formula': {
      'lib': ['library', 'libraries', 'framework', 'frameworks', 'sdk', 'toolkit', 'bindings', 'binding', 'header-only', 'implementation of', 'port of', 'module for', 'runtime library', 'client library', 'language server', 'library for', 'libraries for'],
    },
  };
  Object.keys(table).forEach((kind: string) => {
    const byCategory: Record<string, string[]> = table[kind];
    Object.keys(byCategory).forEach((categoryKey: string) => {
      byCategory[categoryKey].forEach((word: string) => forms.set(`${kind}:${word}`, categoryKey));
    });
  });
  return forms;
}
/** 策展覆盖：`<kind>:<categoryKey>` -> token 数组（人工确定过分类的包；含 Discover 榜单补入的那批） */
function buildOverrides(): Map<string, string[]> {
  const overrides: Map<string, string[]> = new Map<string, string[]>();
  overrides.set('formula:terminal', ['zsh', 'fish', 'starship', 'fzf', 'ripgrep', 'fd', 'bat', 'eza', 'zoxide', 'tmux', 'direnv', 'zsh-autosuggestions', 'zsh-syntax-highlighting', 'atuin', 'herdr', 'hunk', 'leaf-markdown-viewer', 'tuicr', 'herdr', 'hunk', 'leaf-markdown-viewer', 'tuicr']);
  overrides.set('formula:devtools', ['git', 'gh', 'node', 'python@3.12', 'go', 'rust', 'openjdk', 'cmake', 'uv', 'gradle', 'maven', 'llvm', 'gcc', 'ruby', 'lua', 'deno', 'bitwuzla', 'gotestsum', 'makedepend', 'mold', 'pkgconf', 'git-pkgs', 'bitwuzla', 'gotestsum', 'makedepend', 'mold', 'pkgconf']);
  overrides.set('formula:network', ['wget', 'curl', 'httpie', 'aria2', 'rsync', 'nmap', 'mtr', 'speedtest-cli', 'openssh', 'telnet', 'socat', 'doggo', 'network-doctor', 'tailcat', 'network-doctor', 'tailcat']);
  overrides.set('formula:data', ['postgresql@16', 'mysql', 'redis', 'sqlite', 'duckdb', 'jq', 'yq', 'sqlite-utils', 'pgcli', 'mycli', 'miller', 'influxdb', 'sonic', 'sonic']);
  overrides.set('formula:cloudnative', ['kubernetes-cli', 'helm', 'k9s', 'kind', 'minikube', 'opentofu', 'awscli', 'azure-cli', 'colima', 'podman', 'kubectx', 'stern', 'kustomize', 'skaffold', 'gcx', 'vercel', 'gcx', 'vercel']);
  overrides.set('formula:media', ['ffmpeg', 'imagemagick', 'yt-dlp', 'sox', 'exiftool', 'gifsicle', 'pngquant', 'optipng', 'webp', 'libavif', 'libredwg', 'libsndfile', 'libredwg', 'libsndfile']);
  overrides.set('formula:ai', ['ollama', 'llama.cpp', 'whisper.cpp', 'poetry', 'mlx', 'mlx-lm', 'llm', 'tesseract', 'opencv', 'ggml', 'gascity', 'open-code-review', 'gascity', 'open-code-review']);
  overrides.set('formula:system', ['htop', 'btop', 'ncdu', 'dust', 'tree', 'coreutils', 'gnu-sed', 'watch', 'mas', 'bottom', 'procs', 'duf']);
  overrides.set('cask:devide', ['visual-studio-code', 'cursor', 'zed', 'intellij-idea', 'pycharm', 'webstorm', 'datagrip', 'sublime-text', 'android-studio', 'github', 'sourcetree', 'tableplus', 'postman', 'insomnia', 'android-cli', 'android-platform-tools', 'gcloud-cli', 'git-credential-manager', 'ngrok', 'sentry-cli', 'unity-cli', 'zcode', 'android-cli', 'android-platform-tools', 'gcloud-cli', 'git-credential-manager', 'ngrok', 'sentry-cli', 'unity-cli', 'zcode']);
  overrides.set('cask:browser', ['google-chrome', 'firefox', 'arc', 'brave-browser', 'microsoft-edge', 'zen', 'opera', 'vivaldi', 'chromium', 'tor-browser']);
  overrides.set('cask:productivity', ['raycast', 'alfred', 'rectangle', 'obsidian', 'notion', 'logseq', 'craft', 'ticktick', 'fantastical', 'bettertouchtool', 'hammerspoon', 'aldente', '1password-cli', '1password-cli']);
  overrides.set('cask:comm', ['slack', 'discord', 'zoom', 'telegram', 'wechat', 'feishu', 'microsoft-teams', 'whatsapp', 'signal', 'element', 'linear', 'loom']);
  overrides.set('cask:design', ['figma', 'sketch', 'affinity-designer', 'affinity-photo', 'affinity-publisher', 'blender', 'krita', 'lunacy', 'gimp', 'inkscape', 'canva', 'screen-studio', 'font-noto-color-emoji', 'font-noto-color-emoji']);
  overrides.set('cask:av', ['iina', 'vlc', 'subtitle-edit', 'obs', 'audacity', 'spotify', 'elmedia-player', 'movist-pro', 'kap', 'screenflow', 'permute', 'downie']);
  overrides.set('cask:systemtool', ['iterm2', 'warp', 'ghostty', 'appcleaner', 'stats', 'keka', 'balenaetcher', 'istat-menus', 'cleanmymac', 'onyx', 'lulu', 'the-unarchiver', 'grandperspective', 'coconutbattery', 'caskhub', 'cleanmymac-cli', 'crisp', 'homebrew-app', 'openlogi', 'vorssaint', 'caskhub', 'cleanmymac-cli', 'crisp', 'homebrew-app', 'openlogi', 'vorssaint']);
  overrides.set('cask:aivm', ['chatgpt', 'claude', 'lm-studio', 'jan', 'msty', 'docker-desktop', 'orbstack', 'utm', 'parallels', 'virtualbox', 'podman-desktop', 'rancher', 'multipass', 'vagrant', 'claude-code', 'codex', 'grok-bot', 'hermes-desktop', 'lm-studio-bionic', 'claude-code', 'codex', 'grok-bot', 'hermes-desktop', 'lm-studio-bionic']);
  return overrides;
}

const BREW_LEXICON: Map<string, string[]> = buildLexicon();
const BREW_SUBJECTS: Map<string, string> = buildSubjects();
const BREW_FORMS: Map<string, string> = buildForms();
const BREW_OVERRIDES_BY_KEY: Map<string, string[]> = buildOverrides();

/**
 * `<kind>:<token>` -> categoryKey 的扁平表（构造时展开一次，查询 O(1)）。
 *
 * 注意 key 的拼法：源表的 key 是 `<kind>:<categoryKey>`，展开时要**拆开**再拼成
 * `<kind>:<token>` —— 直接拼 `源 key + ':' + token` 会得到 `formula:devtools:uv` 这种
 * 永远查不到的键（这个错犯过一次：240 个策展分类全废，只剩关键词在猜，
 * 表现是"分类卡少一张、兜底档塞了 73 个包"）。
 */
function buildOverrideIndex(): Map<string, string> {
  const index: Map<string, string> = new Map<string, string>();
  BREW_OVERRIDES_BY_KEY.forEach((tokens: string[], kindKey: string) => {
    const sep: number = kindKey.indexOf(':');
    const kind: string = kindKey.substring(0, sep);
    const categoryKey: string = kindKey.substring(sep + 1);
    tokens.forEach((token: string) => index.set(`${kind}:${token}`, categoryKey));
  });
  return index;
}

const BREW_OVERRIDE_INDEX: Map<string, string> = buildOverrideIndex();

/** 兜底分类：三层都判不出来时归到这一档（两边的 "system" 语义） */
const BREW_CATCH_ALL: Map<string, string> = new Map<string, string>([
  [BrewKind.FORMULA, 'system'],
  [BrewKind.CASK, 'systemtool'],
]);

/** 词表里出现的分类 key（供自检/日志核对） */
export function brewLexiconKeys(): string[] {
  const keys: string[] = [];
  BREW_LEXICON.forEach((words: string[], kindKey: string) => keys.push(`${kindKey}(${words.length})`));
  BREW_SUBJECTS.forEach((categoryKey: string, kindTerm: string) => keys.push(`${kindTerm}->${categoryKey}`));
  return keys;
}

export class BrewTaxonomy {
  /** 取策展覆盖里的分类；没有则 undefined（不要在这里回落到兜底，调用方要看得出"未命中"） */
  public static overrideOf(kind: string, token: string): string | undefined {
    return BREW_OVERRIDE_INDEX.get(`${kind}:${token}`);
  }

  /**
   * 关键词分类。返回 undefined = 判不出来（调用方再走主题层 / 兜底）。
   *
   * 与 `generate.py: classify()` 逐行对应：`head` 取 desc 小写后**前 3 个字母数字片段**
   * （`[a-z0-9]+`），命中词在 head 里记 3 分、否则 1 分；`word in text` 是**子串**判定，
   * 不是分词 —— 所以 `git` 会命中 `github`，这是既有口径，改它会让分类结果与生成器不一致。
   */
  public static classify(kind: string, desc: string): string | undefined {
    const text: string = (desc ?? '').toLowerCase();
    const headWords: string[] = text.match(/[a-z0-9]+/g) ?? [];
    const head: string = headWords.slice(0, 3).join(' ');
    const scores: Map<string, number> = new Map<string, number>();
    BREW_LEXICON.forEach((words: string[], kindKey: string) => {
      const sep: number = kindKey.indexOf(':');
      if (kindKey.substring(0, sep) !== kind) {
        return;
      }
      const key: string = kindKey.substring(sep + 1);
      let total: number = 0;
      words.forEach((word: string) => {
        if (text.indexOf(word) >= 0) {
          total += head.indexOf(word) >= 0 ? 3 : 1;
        }
      });
      if (total > 0) {
        scores.set(key, total);
      }
    });
    if (scores.size === 0) {
      return undefined;
    }
    // 与 Python 的 `sorted(scores.items(), key=-score)` 同序：Map 保持插入顺序，排序稳定
    let topKey: string = '';
    let topScore: number = 0;
    let secondScore: number = 0;
    scores.forEach((score: number, key: string) => {
      if (score > topScore) {
        secondScore = topScore;
        topScore = score;
        topKey = key;
      } else if (score > secondScore) {
        secondScore = score;
      }
    });
    if (topScore >= BREW_LEXICON_THRESHOLD.minScore &&
      (topScore - secondScore) >= BREW_LEXICON_THRESHOLD.minMargin) {
      return topKey;
    }
    return undefined;
  }

  /** 主题层分类：返回 undefined = 主题词没命中 */
  public static subjectOf(kind: string, desc: string): string | undefined {
    const terms: string[] = subjectTerms(desc);
    for (let i = 0; i < terms.length; i++) {
      const hit: string | undefined = BREW_SUBJECTS.get(`${kind}:${terms[i]}`);
      if (hit !== undefined) {
        return hit;
      }
    }
    return undefined;
  }

  /**
   * 形态兜底桶：前三层都判不出来、而描述形态上就是「库/框架/SDK」的，归到 `lib`。
   *
   * 与关键词层的区别：**不参与打分**，只在最后一步生效 —— 所以它不会抢走任何已有分类
   * （把同样这些词放进关键词层实测会造成 9 条翻转，兜底率却只差 0.4pt）。
   */
  public static formBucketOf(kind: string, desc: string): string | undefined {
    const text: string = (desc ?? '').toLowerCase();
    let hit: string | undefined = undefined;
    BREW_FORMS.forEach((categoryKey: string, kindWord: string) => {
      if (hit !== undefined) {
        return;
      }
      const sep: number = kindWord.indexOf(':');
      if (kindWord.substring(0, sep) !== kind) {
        return;
      }
      if (text.indexOf(kindWord.substring(sep + 1)) >= 0) {
        hit = categoryKey;
      }
    });
    return hit;
  }

  /**
   * 最终分类：策展覆盖 → 关键词 → 主题词 → 形态桶 → 兜底。**这是本层唯一该被调用的入口。**
   *
   * 返回值保证是 `categories.json` 里存在的 key，所以调用方不必再校验。
   */
  public static categoryOf(kind: string, token: string, desc: string): string {
    const curated: string | undefined = BrewTaxonomy.overrideOf(kind, token);
    if (curated !== undefined) {
      return curated;
    }
    const byKeyword: string | undefined = BrewTaxonomy.classify(kind, desc);
    if (byKeyword !== undefined) {
      return byKeyword;
    }
    const bySubject: string | undefined = BrewTaxonomy.subjectOf(kind, desc);
    if (bySubject !== undefined) {
      return bySubject;
    }
    const byForm: string | undefined = BrewTaxonomy.formBucketOf(kind, desc);
    if (byForm !== undefined) {
      return byForm;
    }
    return BREW_CATCH_ALL.get(kind) ?? 'system';
  }
}
