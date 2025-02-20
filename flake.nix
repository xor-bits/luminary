{
  description = "Nix devenv";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [
          (final: prev: {
            shader-slang = (prev.shader-slang.override {
              spirv-headers = (prev.spirv-headers.overrideAttrs {
                src = prev.fetchFromGitHub {
                  owner = "KhronosGroup";
                  repo = "SPIRV-Headers";
                  rev = "09913f088a1197aba4aefd300a876b2ebbaa3391";
                  hash = "sha256-Q1i6i5XimULuGufP6mimwDW674anAETUiIEvDQwvg5Y=";
                };
              });
            }).overrideAttrs (old: rec {
              version = "2025.5.1";
              src = prev.fetchFromGitHub {
                owner = "shader-slang";
                repo = "slang";
                tag = "v${version}";
                hash = "sha256-OaFO/P4lrxw+0AeX/hEuSBYdxbvMqb0TbCCQs4LKYa0=";
                fetchSubmodules = true;
              };
            });
          })
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
            # shader-slang
            shaderc
            rust-analyzer
            glsl_analyzer
            renderdoc
            rustup

            # required by winit
            xorg.libX11
            xorg.libXcursor
            xorg.libXrandr
            xorg.libXi
            wayland
            libxkbcommon

            # required by Vulkan
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
