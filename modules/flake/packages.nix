{ inputs, lib, ... }:
{
  perSystem = { pkgs, inputs', self', ... }: {
    packages = {
      default =
        let
          mkSearchForModule = modules: baseHref: inputs'.search.packages.mkSearch {
            inherit modules baseHref;
            urlPrefix = "https://github.com/stepbrobd/router/blob/master/";
          };
          mkSite = baseHref: pkgs.linkFarm "ghp" ((
            lib.mapAttrsToList
              (name: value: {
                inherit name;
                path = mkSearchForModule [ value ] "${baseHref}/${name}/";
              })
              inputs.self.nixosModules
          ) ++ [{ name = "slides.pdf"; path = self'.packages.slides; }]);
        in
        (mkSite "/router").overrideAttrs (_: {
          passthru = { inherit mkSearchForModule mkSite; };
        });
      slides = pkgs.stdenvNoCC.mkDerivation {
        name = "slides";
        version = with inputs; self.shortRev or self.dirtyShortRev;
        src = ../../docs;
        nativeBuildInputs = with pkgs; [ typst ];
        buildPhase = "typst compile main.typ main.pdf";
        installPhase = "mv main.pdf $out";
      };
    };
  };
}
