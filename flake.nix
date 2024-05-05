{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    angular-language-server = {
      url = "github:junglerobba/angular-language-server.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, ... }@inputs:
    inputs.flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = inputs.nixpkgs.legacyPackages.${system};
        nodejs = pkgs.nodejs_20;
        nativeBuildInputs = with pkgs; [ nodejs nodePackages."@angular/cli" ];
        name = (pkgs.lib.importJSON ./package.json).name;
        app = env:
          let
            cleanSrc = pkgs.nix-gitignore.gitignoreSourcePure [
              "*.nix"
              ".angular"
              ".direnv"
              "dist"
              "node_modules"
              "result"
            ] (pkgs.lib.cleanSource ./.);
          in pkgs.buildNpmPackage {
            inherit name nativeBuildInputs nodejs;
            version = builtins.substring 0 8 self.lastModifiedDate;
            src = cleanSrc;
            npmDeps = pkgs.fetchNpmDeps {
              src = cleanSrc;
              hash = "sha256-KguUkUvtosjFEZTPDEcvXPfaDgbRd7es6PtSz0el+a8=";
            };
            buildPhase = ''
              ng build --configuration=${env}
            '';
            installPhase = ''
              mkdir -p $out
              cp -r dist/* $out
            '';
          };
        nginxPort = "80";
        nginxConf = app:
          pkgs.writeText "nginx.conf" ''
            user nobody nobody;
            daemon off;
            error_log /dev/stdout info;
            pid /dev/null;
            events {}
            http {
              include ${pkgs.nginx}/conf/mime.types;
              access_log /dev/stdout;
              server {
                listen ${nginxPort};
                index index.html;
                location / {
                  root ${app}/${name}/browser;
                }
              }
            }
          '';
        docker = env:
          let
            build = app env;
            conf = nginxConf build;
          in pkgs.dockerTools.buildLayeredImage {
            inherit name;
            tag = "${env}-${build.version}";
            created = builtins.substring 0 8 self.lastModifiedDate;
            contents = with pkgs; [ fakeNss ];
            config = {
              Cmd = [ "${pkgs.nginx}/bin/nginx" "-c" "${conf}" ];
              ExposedPorts."${nginxPort}/tcp" = { };
            };
            extraCommands = ''
              mkdir -p var/log/nginx
              mkdir -p var/cache/nginx
              mkdir -p tmp
            '';
          };
        envs = with pkgs.lib;
          let
            angular = importJSON ./angular.json;
            configurations =
              angular.projects.${name}.architect.build.configurations;
          in attrNames configurations;
        forAllEnvs = fn: builtins.listToAttrs (builtins.map fn envs);
        apps = forAllEnvs (env: {
          name = env;
          value = app env;
        });
        images = forAllEnvs (env: {
          name = "docker:${env}";
          value = docker env;
        });
      in {
        packages = apps // images // { default = apps.development; };
        devShells.default = pkgs.mkShell {
          inherit nativeBuildInputs;
          packages = with pkgs; [
            inputs.angular-language-server.packages.${system}.default
            nodePackages.eslint
            nodePackages.prettier
            nodePackages.typescript-language-server
            vscode-langservers-extracted
          ];
        };
      });
}

