# Mooniswap tests

This repository contains property based tests writen as part of the Mooniswap audit.

To run these tests first [install nix](https://nixos.org/guides/install-nix.html), and then execute the following:

```
git clone --recursive https://github.com:dapp-org/mooniswap-tests.git && cd mooniswap-tests
nix-shell --pure --command make
```

The following test is expected to fail:

```
testReferalGainsOddity
```

## Development

Run `./dapp.sh` instead of `dapp` to fix imports etc.
