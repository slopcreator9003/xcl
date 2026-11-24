{
  description = "XCL development shell for Linux: cross-build xcl.exe (x86_64-pc-windows-gnu) and run it under Wine + vkd3d-proton";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };
      mingw = pkgs.pkgsCross.mingw-msvcrt-x86_64;

      rust = pkgs.rust-bin.stable.latest.default.override {
        extensions = [ "rust-src" "clippy" ];
        targets = [ "x86_64-pc-windows-gnu" ];
      };

      # vkd3d-proton (D3D12 -> Vulkan) built for Windows from source, so that Wine can load it as
      # d3d12.dll. Patched: XCL replaces the vtable pointer of D3D12 objects it hands to titles
      # (hle/d3d12x/real.rs, `adopt`), and vkd3d-proton's checks of an object's vtable (asserts,
      # and the fence / allocator / command list lookups) refused those objects.
      vkd3d-proton = mingw.vkd3d-proton.overrideAttrs (old: {
        version = "3.1";
        src = pkgs.fetchFromGitHub {
          owner = "HansKristian-Work";
          repo = "vkd3d-proton";
          tag = "v3.1";
          fetchSubmodules = true;
          # meson's vcs_tag needs git; record what it would read, then drop .git (as nixpkgs does)
          deepClone = true;
          postFetch = ''
            cd $out
            mkdir -p .nixpkgs-auxfiles/
            git describe --always --exclude='*' --abbrev=15 --dirty=0 > .nixpkgs-auxfiles/vkd3d_build
            git describe --always --tags --dirty=+ > .nixpkgs-auxfiles/vkd3d_version
            find $out -name .git -print0 | xargs -0 rm -fr
          '';
          hash = "sha256-OfojrwbORfWfOusec9/RgxFurqeXTC43xGiEJ9SQXFE=";
        };
        patches = (old.patches or [ ]) ++ [ ./nix/vkd3d-proton-xcl-vtables.patch ];
        # build tools for Linux (widl comes from Wine); the cross package's own `wine` input
        # cannot be evaluated for Windows
        nativeBuildInputs = [ pkgs.glslang pkgs.meson pkgs.ninja wine ];
        buildInputs = [ mingw.windows.pthreads ]; # -pthread, linked statically
        mesonBuildType = "release"; # as upstream's releases (nixpkgs' default is "plain": no -O)
        outputs = [ "out" ];
        meta = old.meta // { platforms = pkgs.lib.platforms.windows; };
      });

      # Windows DXC (dxcompiler.dll + dxil.dll), loaded by XCL at run time through XCL_DXC_DIR.
      # (The zip uses backslashes as path separators, which unzip / fetchzip refuse; 7-Zip copes.)
      dxc = pkgs.runCommand "dxc-windows-1.9.2609" { nativeBuildInputs = [ pkgs._7zz ]; } ''
        mkdir -p $out/bin/x64 src
        7zz x -osrc ${pkgs.fetchurl {
          url = "https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2609/dxc_2026_09_29.zip";
          hash = "sha256-rTGx/IRDF10gT3emEf2z7y7EJ1m9wvEWc2jeJKSn5/E=";
        }}
        cp 'src/bin\x64\dxcompiler.dll' $out/bin/x64/dxcompiler.dll
        cp 'src/bin\x64\dxil.dll' $out/bin/x64/dxil.dll
        cp src/LICEN*.txt $out/
      '';

      wine = pkgs.wineWow64Packages.staging;

      # Creates the Wine prefix (if needed) and installs vkd3d-proton's d3d12.dll / d3d12core.dll in it.
      xcl-wine-init = pkgs.writeShellScriptBin "xcl-wine-init" ''
        set -eu
        : "''${WINEPREFIX:?WINEPREFIX is not set (enter the shell with nix develop)}"
        mkdir -p "$WINEPREFIX"
        # no wine-mono / wine-gecko: XCL needs neither, and their install prompt blocks wineboot
        WINEDLLOVERRIDES="mscoree,mshtml=" ${wine}/bin/wineboot -u
        ${wine}/bin/wineserver -w
        sys32="$WINEPREFIX/drive_c/windows/system32"
        for f in d3d12.dll d3d12core.dll; do
          install -m 644 "${vkd3d-proton}/bin/$f" "$sys32/$f"
        done
        echo "vkd3d-proton 3.1 (XCL vtable patch) installed in $sys32"
      '';
    in
    {
      packages.${system}.vkd3d-proton = vkd3d-proton;

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          rust
          mingw.stdenv.cc
          wine
          xcl-wine-init
          pkgs.vulkan-tools
          pkgs.vulkan-loader
          pkgs.git
          pkgs.gh
          pkgs.powershell # scripts/*.ps1
          pkgs.python3 # scripts/*.py
        ];

        # cargo build / cargo test cross-compile for Windows and run the results under Wine
        CARGO_BUILD_TARGET = "x86_64-pc-windows-gnu";
        CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "${mingw.stdenv.cc}/bin/x86_64-w64-mingw32-cc";
        CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUNNER = "${wine}/bin/wine";
        CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = "-L native=${mingw.windows.pthreads}/lib";

        WINEDLLOVERRIDES = "d3d12,d3d12core=n,b";
        WINEDEBUG = "-all";
        XCL_DXC_DIR = "Z:${builtins.replaceStrings [ "/" ] [ "\\" ] "${dxc}/bin/x64"}";

        shellHook = ''
          export WINEPREFIX="$PWD/target/wineprefix"
          if [ ! -f "$WINEPREFIX/drive_c/windows/system32/d3d12core.dll" ]; then
            echo "xcl: no Wine prefix with vkd3d-proton yet; run xcl-wine-init"
          fi
        '';
      };
    };
}
