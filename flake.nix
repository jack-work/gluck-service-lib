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

        # A tiny wrapper for the rare service that isn't Python. Skips
        # pythonPackages / entrypoint and takes an ExecStart directly.
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
          }:
          {
            systemd.services.${name} = {
              description = "${name} — via gluck-service-lib";
              inherit after wants;
              wantedBy = [ "multi-user.target" ];
              environment = { PORT = toString port; } // environment;
              serviceConfig = defaultHardened // {
                DynamicUser = true;
                StateDirectory = stateDirectory;
                ExecStart = execStart;
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
      };
    };
}
