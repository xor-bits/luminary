{
  description = "Nix devenv";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
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
            # shader-slang
            shaderc
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
