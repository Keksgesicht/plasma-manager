# Low-level access to changing Plasma settings.
{ config, lib, pkgs, ... }:

let
  inherit (import ../lib/kwriteconfig.nix { inherit lib pkgs; })
    kWriteConfig;

  # Helper function to prepend the appropriate path prefix (e.g. XDG_CONFIG_HOME) to file
  prependPath = prefix: attrset:
    lib.attrsets.mapAttrs'
      (path: config: { name = "${prefix}/${path}"; value = config; })
      attrset;
  plasmaCfg = config.programs.plasma;
  cfg =
    (prependPath config.home.homeDirectory plasmaCfg.file) //
    (prependPath config.xdg.configHome plasmaCfg.configFile) //
    (prependPath config.xdg.dataHome plasmaCfg.dataFile);

  ##############################################################################
  # A module for storing settings.
  settingType = { name, ... }: {
    freeformType = with lib.types;
      attrsOf (nullOr (oneOf [ bool float int str ]));

    options = {
      configGroupNesting = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        # We allow escaping periods using \\.
        default = (map
          (e: builtins.replaceStrings [ "\\u002E" ] [ "." ] e)
          (lib.splitString "."
            (builtins.replaceStrings [ "\\." ] [ "\\u002E" ] name)
          )
        );
        description = "Group name, and sub-group names.";
      };
    };
  };

  ##############################################################################
  # Remove reserved options from a settings attribute set.
  settingsToConfig = settings:
    lib.filterAttrs
      (k: v: !(builtins.elem k [ "configGroupNesting" ]))
      settings;

  ##############################################################################
  # Generate a script that will use kwriteconfig to update all
  # settings.
  script = pkgs.writeScript "plasma-config"
    (lib.concatStrings
      (lib.mapAttrsToList
        (file: settings: lib.concatMapStringsSep "\n"
          (set: kWriteConfig file set.configGroupNesting (settingsToConfig set))
          (builtins.attrValues settings))
        cfg));

  ##############################################################################
  # Generate a script that will remove all the current config files.
  filesToReset = [
    "kded5rc"
    "kdeglobals"
    "kglobalshortcutsrc"
    "khotkeysrc"
    "krunnerrc"
    "kwinrc"
    "plasmarc"
    "plasmashellrc"
  ];
  resetScript = pkgs.writeScript "reset-plasma-config"
    (builtins.concatStringsSep
      "\n"
      (map (e: "if [ -f ${config.xdg.configHome}/${e} ]; then rm ${config.xdg.configHome}/${e}; fi") filesToReset));
in
{
  options.programs.plasma = {
    file = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf (submodule settingType));
      default = { };
      description = ''
        An attribute set where the keys are file names (relative to
        HOME) and the values are attribute sets that represent
        configuration groups and settings inside those groups.
      '';
    };
    configFile = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf (submodule settingType));
      default = { };
      description = ''
        An attribute set where the keys are file names (relative to
        XDG_CONFIG_HOME) and the values are attribute sets that
        represent configuration groups and settings inside those groups.
      '';
    };
    dataFile = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf (submodule settingType));
      default = { };
      description = ''
        An attribute set where the keys are file names (relative to
        XDG_DATA_HOME) and the values are attribute sets that
        represent configuration groups and settings inside those groups.
      '';
    };
    overrideConfig = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Wether to discard changes made outside plasma-manager. If enabled all
        settings not specified explicitly in plasma-manager will be set to the
        default on next login.
      '';
    };
  };

  imports = [
    (lib.mkRenamedOptionModule [ "programs" "plasma" "files" ] [ "programs" "plasma" "configFile" ])
  ];

  config = lib.mkIf (plasmaCfg.enable && (builtins.length (builtins.attrNames cfg) > 0)) {
    home.activation.configure-plasma = (lib.hm.dag.entryAfter [ "writeBoundary" ]
      ''
        $DRY_RUN_CMD ${if config.programs.plasma.overrideConfig then resetScript else ""}
        $DRY_RUN_CMD ${script}
      '');
  };
}
