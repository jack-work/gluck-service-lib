# gluck-service-lib

Reusable factoring for services behind
[kelliher-web](https://github.com/jack-work/kelliher-web).

One `mkPythonService {…}` call emits:

- a hardened systemd unit (DynamicUser, StateDirectory, on-failure restart)
- a `services.kelliher-web.sites.<name>` registration
- optional Authelia gating (`requireAuth = true`)
- optional lldap capability groups (`requiredGroups = […]`, wired
  automatically by the host's identity layer via
  `services.kelliher-web.allRequiredGroups`)

See [`gluck-calendar`](https://github.com/jack-work/gluck-calendar) for
the canonical consumer.

## Usage sketch

```nix
{
  inputs = {
    nixpkgs.url         = "github:NixOS/nixpkgs/nixos-unstable";
    gluck-service-lib.url = "github:jack-work/gluck-service-lib";
  };

  outputs = { self, nixpkgs, gluck-service-lib, ... }: {
    nixosModules.default = { config, lib, pkgs, ... }: {
      options.services.my-thing.enable =
        lib.mkEnableOption "my-thing";

      config = lib.mkIf config.services.my-thing.enable (
        gluck-service-lib.lib.mkPythonService {
          inherit config lib pkgs;
          name           = "my-thing";
          subdomain      = "thing";
          port           = 9095;
          entrypoint     = ./my_thing.py;
          pythonPackages = ps: with ps; [ flask waitress duckdb ];
          requireAuth    = true;
          requiredGroups = [ "gluck-my-thing-create" ];
        }
      );
    };
  };
}
```

## What you still write per service

- The app itself (Python file, its handlers, its DB schema)
- A NixOS `services.<name>.enable` option so spain-flake can turn it on
- Any host-level wiring (Authelia OIDC client, sops secrets) — those live
  in `spain-flake/identity.nix`, not here
