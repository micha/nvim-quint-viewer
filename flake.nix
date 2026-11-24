{
  description = "Development shell for nvim-quint-viewer";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }:
    {
      devShells = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ] (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          quint = pkgs.buildNpmPackage rec {
            pname = "quint-cli";
            version = "0.33.1";
            src = pkgs.fetchFromGitHub {
              owner = "quint-co";
              repo = "quint";
              tag = "v${version}";
              hash = "sha256-F0Yj9e+qTOlj6RzspvkEhilXC6pFHvISBRLgvJmon7I=";
            };
            sourceRoot = "${src.name}/quint";
            npmDepsHash = "sha256-Bk21CfCh1xsY1cIYnSQfxxcpVkRbBg5EfGbFvJlTcvE=";
            npmBuildScript = "compile";
            npmFlags = [ "--ignore-scripts" ];
          };
          # Quint 0.33.1 uses this distribution for both verification backends.
          apalacheVersion = "0.62.4";
          apalacheDist = pkgs.fetchurl {
            url = "https://github.com/apalache-mc/apalache/releases/download/v${apalacheVersion}/apalache.tgz";
            hash = "sha256-ishIhCLDDVUnNbrhG5Ki0BTY4C6GCHAqzAj5otipq7I=";
          };
          apalacheCache = pkgs.runCommand "quint-apalache-${apalacheVersion}" {} ''
            mkdir -p "$out/apalache-dist-${apalacheVersion}"
            tar -xf ${apalacheDist} -C "$out/apalache-dist-${apalacheVersion}"
          '';
        in
        {
          default = pkgs.mkShell {
            packages = [ pkgs.git pkgs.neovim pkgs.python3 quint ];
          };
          spec = pkgs.mkShell {
            packages = [ quint pkgs.jdk_headless ];
            QMODEL_APALACHE_CACHE = apalacheCache;
          };
        });
    };
}
