{ lib
, rustPlatform
, makeWrapper
, m4
}:

rustPlatform.buildRustPackage {
  pname = "router";
  version = (lib.importTOML ../../Cargo.toml).package.version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../Cargo.toml
      ../../Cargo.lock
      ../../src
      ../../registry
      ../../license.txt
    ];
  };

  cargoLock.lockFile = ../../Cargo.lock;
  useNextest = true;

  nativeBuildInputs = [ makeWrapper m4 ];

  postInstall = ''
    wrapProgram "$out/bin/router" \
      --prefix PATH : ${lib.makeBinPath [ m4 ]}
  '';

  meta = {
    description = "BIRD source grammar compiler and Nix configuration backend generator";
    license = lib.licenses.mit;
    mainProgram = "router";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
