let
  pkgs = import (builtins.fetchGit rec {
    name = "dapptools-${rev}";
    url = https://github.com/dapphub/dapptools;
    rev = "1b01540c1c30e1f3d3496ddf62e2b04bba575aa5";
    # ref = "solc-0.6.12";
  }) {};

in
  pkgs.mkShell {
    src = null;
    name = "mooniswap-tests";
    buildInputs = with pkgs; [
      pkgs.dapp
    ];
  }
