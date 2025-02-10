{
  description = "Nix devenv";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zigpkgs.url = "github:mitchellh/zig-overlay";
  };

  outputs = { nixpkgs, flake-utils, zigpkgs, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
      in
      {
        # `nix develop`
        devShells.default = pkgs.mkShell rec {
          buildInputs = with pkgs; [
            pkg-config
            # zig.packages."${system}".master
            zig
            glfw

            # vulkan-headers
            vulkan-loader # validation layer(s)
            # vulkan-memory-allocator # VMA
          ];

          LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath buildInputs}";
        };
      }
    );
}
