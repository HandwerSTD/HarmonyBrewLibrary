import { describe, it, expect } from '@ohos/hypium';
import { BrewCommandGenerator, BrewKind } from '../../../../Index';
import type { BrewCaskDetail, BrewFormulaDetail } from '../../../../Index';

/**
 * BrewCommandGenerator 单元测试。
 *
 * 决策背景：详情页安装命令区只展示基础命令，不做交互式安装选项
 * （官方 API 的 options 字段实测恒为空），因此生成器只负责命令拼装。
 */

/** 完整 fixture：ArkTS 对象字面量必须覆盖接口的全部字段 */
function formulaDetail(): BrewFormulaDetail {
  return {
    id: 1005,
    token: 'ripgrep',
    fullToken: 'ripgrep',
    tap: 'homebrew/core',
    name: 'ripgrep',
    desc: 'Search tool like grep and The Silver Searcher',
    homepage: 'https://github.com/BurntSushi/ripgrep',
    license: 'Unlicense',
    stableVersion: '15.2.0',
    headVersion: '',
    versionedFormulae: [],
    aliases: [],
    kegOnly: false,
    kegOnlyReason: null,
    serviceSupported: false,
    serviceRun: [],
    serviceRunType: '',
    executables: ['rg'],
    requirements: [],
    caveats: '',
    bottleAvailable: true,
    bottleTags: ['arm64_sequoia', 'sonoma'],
    bottleRebuild: 1,
    dependencies: [{ name: 'pcre2', fullName: 'pcre2' }],
    buildDependencies: [],
    optionalDependencies: [],
    recommendedDependencies: [],
    usesFromMacos: [],
    conflictsWith: [],
    installs30d: 35603,
    installs90d: 158667,
    installs365d: 515566,
    categoryRank: 3,
    categorySize: 14,
    installCommand: 'brew install ripgrep',
    categoryKey: 'terminal',
    deprecated: false,
    deprecationDate: '',
    deprecationReason: '',
    deprecationReplacementFormula: '',
    deprecationReplacementCask: '',
    disabled: false,
    disableDate: '',
    disableReason: '',
  };
}

function thirdPartyFormulaDetail(): BrewFormulaDetail {
  const detail: BrewFormulaDetail = formulaDetail();
  detail.token = 'mongodb-community';
  detail.tap = 'mongodb/brew';
  detail.installCommand = '';
  return detail;
}

function caskDetail(): BrewCaskDetail {
  return {
    id: 2025,
    token: 'raycast',
    fullToken: 'raycast',
    tap: 'homebrew/cask',
    name: 'Raycast',
    names: ['Raycast'],
    desc: 'Control your tools with a few keystrokes',
    homepage: 'https://raycast.com/',
    version: '2.4.1.0',
    autoUpdates: true,
    supportedPlatforms: ['arm64_sequoia', 'sequoia'],
    macosRequirement: 'macOS >= 14',
    bundleVersion: 0,
    artifacts: [{ artifactType: 'app', path: 'Raycast.app' }],
    zapPathCount: 10,
    dependsOn: {
      formula: [],
      cask: [],
      macos: {},
      arch: [{ type: 'arm', bits: 64 }],
    },
    conflictsWith: [],
    caveats: '',
    installs30d: 7282,
    installs90d: 26778,
    installs365d: 116988,
    categoryRank: 1,
    categorySize: 12,
    installCommand: 'brew install --cask raycast',
    categoryKey: 'productivity',
    deprecated: false,
    deprecationDate: '',
    deprecationReason: '',
    deprecationReplacementFormula: '',
    deprecationReplacementCask: '',
    disabled: false,
    disableDate: '',
    disableReason: '',
  };
}

export default function commandGeneratorTest() {
  describe('BrewCommandGeneratorTest', () => {
    it('baseCommand_formula', 0, () => {
      expect(BrewCommandGenerator.baseCommand(BrewKind.FORMULA, 'ripgrep', 'homebrew/core'))
        .assertEqual('brew install ripgrep');
    });

    it('baseCommand_cask', 0, () => {
      expect(BrewCommandGenerator.baseCommand(BrewKind.CASK, 'raycast', 'homebrew/cask'))
        .assertEqual('brew install --cask raycast');
    });

    it('qualifiedName_official_tap_uses_bare_token', 0, () => {
      expect(BrewCommandGenerator.qualifiedName('ripgrep', 'homebrew/core')).assertEqual('ripgrep');
      expect(BrewCommandGenerator.qualifiedName('raycast', 'homebrew/cask')).assertEqual('raycast');
    });

    it('qualifiedName_third_party_tap_prefixed', 0, () => {
      expect(BrewCommandGenerator.qualifiedName('mongodb-community', 'mongodb/brew'))
        .assertEqual('mongodb/brew/mongodb-community');
    });

    it('installCommandOf_prefers_data_field', 0, () => {
      const detail: BrewFormulaDetail = formulaDetail();
      expect(BrewCommandGenerator.installCommandOf(detail, BrewKind.FORMULA))
        .assertEqual('brew install ripgrep');
    });

    it('installCommandOf_falls_back_when_empty', 0, () => {
      const detail: BrewFormulaDetail = thirdPartyFormulaDetail();
      expect(BrewCommandGenerator.installCommandOf(detail, BrewKind.FORMULA))
        .assertEqual('brew install mongodb/brew/mongodb-community');
    });

    it('installCommandOf_cask', 0, () => {
      const detail: BrewCaskDetail = caskDetail();
      expect(BrewCommandGenerator.installCommandOf(detail, BrewKind.CASK))
        .assertEqual('brew install --cask raycast');
    });

    it('uninstall_commands', 0, () => {
      expect(BrewCommandGenerator.uninstallCommand(BrewKind.FORMULA, 'ripgrep', 'homebrew/core'))
        .assertEqual('brew uninstall ripgrep');
      expect(BrewCommandGenerator.uninstallCommand(BrewKind.CASK, 'raycast', 'homebrew/cask'))
        .assertEqual('brew uninstall --cask raycast');
    });

    it('upgrade_commands', 0, () => {
      expect(BrewCommandGenerator.upgradeCommand(BrewKind.FORMULA, 'ripgrep', 'homebrew/core'))
        .assertEqual('brew upgrade ripgrep');
      expect(BrewCommandGenerator.upgradeCommand(BrewKind.CASK, 'raycast', 'homebrew/cask'))
        .assertEqual('brew upgrade --cask raycast');
    });
  });
}
