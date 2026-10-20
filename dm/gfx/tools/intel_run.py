#!/usr/bin/env python3
# Runs the shader build chain on an Intel Mac (for use by scripts/build_ipa_from_nsp.py, which calls it there instead of running dmsh_build.py directly).
# Usage: intel_run.py <script.py> [args...]   Example: intel_run.py dmsh_build.py <package dir> <cache dir>
# How: like nometal_run.py, not a single file of the build chain is modified (their contents feed into the translation chain version, and any change would force new shader libraries for every profile);
# within this process only two entries are taken over, and the compilers and their outputs are the same as on Apple silicon:
#   <dir>/dmsh_xlate ...        the translator's apphost is an arm64 executable, which an Intel Mac cannot start → dotnet <dir>/dmsh_xlate.dll ... (the same managed code: its dll fingerprints are unchanged)
#   dmsh_chain.tools_now()      Homebrew's spirv-cross is another binary on Intel, so its file fingerprint never matches the lock (written on Apple silicon); the lock's value is taken instead,
#                               with a note naming the installed spirv-cross revision. Every other fingerprint (translator dlls, Metal compilers) is still checked against the lock.
#   DMSH_ANY_METAL=1            also takes the lock's Metal compiler versions in place of the installed ones (the NSP script's --any-metal: an Intel Mac that cannot run the Xcode the lock names,
#                               macOS Sequoia's last being 26.3). The libraries are compiled from the same Metal source by an older compiler: not byte-identical to the reference build, not tested on a device
import os, runpy, shutil, subprocess, sys

_real = subprocess.run


def run(args, *a, **k):
    if isinstance(args, (list, tuple)) and args:
        c = [str(x) for x in args]
        if os.path.basename(c[0]) == 'dmsh_xlate' and os.path.exists(c[0] + '.dll'):
            args = [shutil.which('dotnet') or 'dotnet', c[0] + '.dll', *c[1:]]
    return _real(args, *a, **k)


def lock_spirv_cross(chain):
    real = chain.tools_now
    def tools_now():
        t = real()
        lock = dict(l.rstrip('\n').split('\t', 1) for l in open(chain.LOCK) if '\t' in l and not l.startswith('#')); want = lock.get('spirv-cross')
        if want and t.get('spirv-cross') not in (want, 'missing'):
            r = _real(['spirv-cross', '--revision'], capture_output=True, text=True)
            print(f'intel_run: spirv-cross {" ".join((r.stdout + r.stderr).split())} is the Intel build: its file fingerprint is not compared with the lock (Apple silicon)', file=sys.stderr)
            t['spirv-cross'] = want
        if os.environ.get('DMSH_ANY_METAL') == '1':
            for k, v in lock.items():
                if k.startswith('metal_') and t.get(k) not in (v, 'missing'):
                    print(f'intel_run: {k} is {t[k]}, the lock names {v}: compiling with the installed one (DMSH_ANY_METAL)', file=sys.stderr); t[k] = v
        return t
    chain.tools_now = tools_now


if __name__ == '__main__':
    if len(sys.argv) < 2: sys.exit('usage: intel_run.py <script.py> [args...]')
    subprocess.run = run
    script = os.path.abspath(sys.argv[1]); sys.argv = sys.argv[1:]; sys.path.insert(0, os.path.dirname(script))
    import dmsh_chain; lock_spirv_cross(dmsh_chain)   # before the script imports it (dmsh_build.py checks the tools on import)
    runpy.run_path(script, run_name='__main__')
