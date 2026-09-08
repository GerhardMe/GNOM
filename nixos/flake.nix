{
  description = "Gerhard's NixOs Manager System";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      # NixOS system configuration
      # NOTE: attr names are quoted so the un-templated repo flake still
      # parses (needed for `nix build ./nixos#iso`); templating fills them in.
      nixosConfigurations = {
        "{{hostname}}" = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./configuration.nix
            home-manager.nixosModules.home-manager

            # Configure Home Manager user to import home.nix
            ({ config, lib, pkgs, ... }: {
              home-manager.users."{{username}}" = { imports = [ ./home.nix ]; };
            })
          ];
        };

        # Bootable installer ISO (never evaluates the host config above)
        installer = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ../installer/iso.nix ];
        };
      };

      # Build with: nix build ./nixos#iso
      packages.x86_64-linux.iso =
        self.nixosConfigurations.installer.config.system.build.isoImage;
    };
}
