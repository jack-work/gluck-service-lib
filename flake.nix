{
  description = "gluck-service-lib — reusable helpers for services behind kelliher-web";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      # The hardened systemd sandbox every gluck service inherits.
      # DynamicUser + StateDirectory + strict namespace/syscall restrictions.
      # If you need weaker/stronger, override the merged serviceConfig at
      # the call site with a `//`.
      defaultHardened = {
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
      };
    in
    {
      lib = rec {
        inherit defaultHardened;

        # ── mkPythonService ─────────────────────────────────────────────
        #
        # Emit a full "gluck service" from a small spec: hardened systemd
        # unit + Caddy site + optional Authelia gating + optional lldap
        # capability group. Returns a NixOS module you inline into
        # config with lib.mkMerge.
        #
        # Example (in a site flake's outputs = { config, lib, pkgs, ... }: … block):
        #
        #   config = lib.mkMerge [
        #     (gluck-service-lib.lib.mkPythonService {
        #       inherit config lib pkgs;
        #       name        = "gluck-calendar";
        #       subdomain   = "cal";
        #       port        = 9094;
        #       entrypoint  = ./calendar/gluck_calendar.py;
        #       pythonPackages = ps: with ps; [
        #         flask waitress requests duckdb pyjwt cryptography
        #         python-dateutil pytz
        #       ];
        #       stateDirectory = "gluck-calendar";
        #       requireAuth    = true;
        #       requiredGroups = [ "gluck-calendar-create" ];
        #       environment    = { GLUCK_CALENDAR_DB = "/var/lib/gluck-calendar/calendar.duckdb"; };
        #     })
        #   ];
        mkPythonService =
          {
            config,
            lib,
            pkgs,

            # identity + wiring
            name,           # e.g. "gluck-calendar"
            subdomain,      # e.g. "cal"       → cal.<baseDomain>
            extraHostnames ? [ ],
            port,           # loopback port the app binds
            requireAuth ? true,
            requiredGroups ? [ ],

            # code
            entrypoint,             # path to the .py to exec
            pythonPackages ? (_: [ ]),  # ps: [ ps.flask … ]
            environment ? { },
            extraServiceConfig ? { },

            # storage
            stateDirectory ? name,  # /var/lib/<stateDirectory>

            # deps
            after ? [ "network.target" ],
            wants ? [ ],
          }:
          let
            py = pkgs.python3.withPackages pythonPackages;
          in
          {
            systemd.services.${name} = {
              description = "${name} — via gluck-service-lib";
              inherit after wants;
              wantedBy = [ "multi-user.target" ];
              environment = {
                PORT = toString port;
              } // environment;
              serviceConfig = defaultHardened // {
                DynamicUser = true;
                StateDirectory = stateDirectory;
                ExecStart = "${py}/bin/python ${entrypoint}";
                Restart = "on-failure";
                RestartSec = 5;
              } // extraServiceConfig;
            };

            services.kelliher-web.sites.${name} = {
              subdomains = [ subdomain ];
              hostnames = extraHostnames;
              inherit requireAuth requiredGroups;
              proxyTo = port;
            };
          };

        # ── mkScheduledJob ──────────────────────────────────────────────
        #
        # Emit a hardened systemd *oneshot* + *timer* pair for periodic
        # or scheduled work: bank pollers, health probers, snapshot
        # rotators. Same design as mkPythonService but without the Caddy
        # site — jobs don't have a public surface. If a job needs a
        # status/manual-trigger endpoint, expose it on a companion
        # mkPythonService that shells out to `systemctl start`.
        #
        # Manual trigger: `systemctl start <name>.service` on spain
        # runs the job immediately (out-of-band from the timer).
        # Observability: `journalctl -u <name>`, `systemctl list-timers
        # '<name>*'`, `systemctl status <name>.timer`.
        #
        # Example:
        #
        #   config = lib.mkMerge [
        #     (gluck-service-lib.lib.mkScheduledJob {
        #       inherit config lib pkgs;
        #       name = "gluck-plaid-sync";
        #       description = "Plaid transactions sync";
        #       schedule = "*-*-* 00/6:00:00";   # every 6h on the hour
        #       randomizedDelaySec = "10m";
        #       execStart = "${pkgs.my-plaid-sync}/bin/plaid-sync";
        #       runtimePackages = with pkgs; [ python3 curl jq ];
        #       credentials = {
        #         plaid_client_id = "/run/secrets/plaid-client-id";
        #         plaid_secret    = "/run/secrets/plaid-secret";
        #         plaid_items     = "/run/secrets/plaid-items";
        #       };
        #       stateDirectory = "gluck-plaid";
        #       requireNetwork = true;
        #     })
        #   ];
        mkScheduledJob =
          {
            config,
            lib,
            pkgs,

            name,                       # e.g. "gluck-plaid-sync"
            description ? name,
            schedule,                   # systemd OnCalendar string
            randomizedDelaySec ? "5m",
            persistent ? true,          # run on boot if a firing was missed
            accuracySec ? "1min",

            execStart,                  # command line (string) OR list of strings
            environment ? { },
            credentials ? { },          # { name = /path/to/file; } → LoadCredential
            runtimePackages ? [ ],      # available on PATH inside the job

            stateDirectory ? name,      # /var/lib/<stateDirectory>
            readWritePaths ? [ ],       # extra ReadWritePaths (mount points, blob dirs, …)

            user ? null,                # null → DynamicUser=true
            group ? null,

            requireNetwork ? true,
            after ? [ ],
            wants ? [ ],
            requires ? [ ],

            timeoutStartSec ? "15m",    # kill the job if it exceeds this
            restartOnFailure ? false,   # timers usually handle retries; opt in per job
            restartSec ? 30,

            extraServiceConfig ? { },
          }:
          let
            netAfter = lib.optionals requireNetwork [ "network-online.target" ];
            netWants = lib.optionals requireNetwork [ "network-online.target" ];

            execStartValue =
              if builtins.isList execStart then
                lib.concatStringsSep " " execStart
              else
                execStart;

            loadCredential = lib.mapAttrsToList (n: p: "${n}:${p}") credentials;

            userGroupConfig =
              if user == null then
                { DynamicUser = true; }
              else
                {
                  DynamicUser = false;
                  User = user;
                  Group = if group == null then user else group;
                };

            pathEnv = lib.optionalAttrs (runtimePackages != [ ]) {
              PATH = lib.makeBinPath runtimePackages;
            };
          in
          {
            systemd.services.${name} = {
              inherit description;
              after = netAfter ++ after;
              wants = netWants ++ wants;
              inherit requires;
              # NOT wantedBy = multi-user — the timer is what pulls this in.
              environment = environment // pathEnv;
              serviceConfig = defaultHardened // {
                Type = "oneshot";
                StateDirectory = stateDirectory;
                ExecStart = execStartValue;
                TimeoutStartSec = timeoutStartSec;
              }
              // userGroupConfig
              // lib.optionalAttrs (loadCredential != [ ]) {
                LoadCredential = loadCredential;
              }
              // lib.optionalAttrs (readWritePaths != [ ]) {
                ReadWritePaths = readWritePaths;
              }
              // lib.optionalAttrs restartOnFailure {
                Restart = "on-failure";
                RestartSec = restartSec;
              }
              // extraServiceConfig;
            };

            systemd.timers.${name} = {
              inherit description;
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = schedule;
                RandomizedDelaySec = randomizedDelaySec;
                AccuracySec = accuracySec;
                Persistent = persistent;
                Unit = "${name}.service";
              };
            };
          };

        # A tiny wrapper for the rare service that isn't Python. Skips
        # pythonPackages / entrypoint and takes an ExecStart directly.
        #
        # DynamicUser is the default and the right choice for a service that
        # owns nothing but its own StateDirectory: systemd allocates the uid
        # at start, re-chowns the state, and nothing outlives the unit.
        #
        # Set `user` when the service needs a *stable* identity, which is a
        # narrower case than it first appears. The two real reasons:
        #
        #   - a sops secret with `owner = "<user>"`, since a DynamicUser's
        #     uid does not exist at activation time when sops-nix chowns;
        #   - a long-lived store shared with another unit, or files that must
        #     survive with a meaningful owner. A DynamicUser's uid is
        #     recycled, which is how a directory ends up owned by a number
        #     with no name behind it.
        #
        # Prefer `LoadCredential` over a fixed user: it lands the secret in a
        # per-unit tmpfs at 0400, needs no chown ordering, and keeps
        # DynamicUser. Reach for `user` only when that is not enough.
        mkService =
          {
            config,
            lib,
            pkgs,
            name,
            subdomain,
            extraHostnames ? [ ],
            port,
            requireAuth ? true,
            requiredGroups ? [ ],
            execStart,
            environment ? { },
            extraServiceConfig ? { },
            stateDirectory ? name,
            after ? [ "network.target" ],
            wants ? [ ],

            # Fixed identity. null (default) means DynamicUser.
            user ? null,
            group ? null,
            # Create the user/group declaratively. Turn this off when the
            # account is defined elsewhere (an upstream module, or shared
            # with another service).
            createUser ? true,
          }:
          let
            fixedIdentity = user != null;
            groupName = if group != null then group else user;
          in
          {
            users.users = lib.mkIf (fixedIdentity && createUser) {
              ${user} = {
                isSystemUser = true;
                group = groupName;
                description = "${name} service account";
              };
            };
            users.groups = lib.mkIf (fixedIdentity && createUser && group == null) {
              ${user} = { };
            };

            systemd.services.${name} = {
              description = "${name} — via gluck-service-lib";
              inherit after wants;
              wantedBy = [ "multi-user.target" ];
              environment = { PORT = toString port; } // environment;
              serviceConfig =
                defaultHardened
                // {
                  StateDirectory = stateDirectory;
                  ExecStart = execStart;
                  Restart = "on-failure";
                  RestartSec = 5;
                }
                // (
                  if fixedIdentity then
                    {
                      User = user;
                      Group = groupName;
                    }
                  else
                    { DynamicUser = true; }
                )
                // extraServiceConfig;
            };

            services.kelliher-web.sites.${name} = {
              subdomains = [ subdomain ];
              hostnames = extraHostnames;
              inherit requireAuth requiredGroups;
              proxyTo = port;
            };
          };
      };
    };
}
