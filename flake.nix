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
        overlays = [
          # (final: prev: {
          #   shader-slang = prev.shader-slang.overrideAttrs (old: rec {
          #     version = "2025.5.1";
          #     src = prev.fetchFromGitHub {
          #       owner = "shader-slang";
          #       repo = "slang";
          #       tag = "v${version}";
          #       hash = "sha256-OaFO/P4lrxw+0AeX/hEuSBYdxbvMqb0TbCCQs4LKYa0=";
          #       fetchSubmodules = true;
          #     };
          #   });
          # })
        ];
        pkgs = import nixpkgs {
          inherit system overlays;
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
            # shader-slang
            shaderc
            glsl_analyzer
            renderdoc

            vulkan-loader
            # vulkan-tools-lunarg # vkconfig
          ];

          # VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d:${pkgs.vulkan-extension-layer}/share/vulkan/explicit_layer.d";
          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
          LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath buildInputs}";
        };
      }
    );
}
