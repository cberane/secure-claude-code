#!/usr/bin/env bash
# doctor.sh — hardening self-test. Covers the 19 acceptance criteria, plus
# per-toolchain function checks (20-23) for each enabled toolchain.
#
#   scripts/doctor.sh --host   : run on the HOST (via `make doctor`).
#                                Runs host-side checks 11 and 15, and executes
#                                the container-side checks via compose.
#   doctor (inside container)  : container-side checks (all others).
#
# Output: one green PASS / red FAIL line per check, non-zero exit if any fail.
set -u

PASS=0
FAIL=0
GREEN='\033[32m'; RED='\033[31m'; RESET='\033[0m'

report() { # report <num> <ok:0|1> <description> [detail]
    local num="$1" ok="$2" desc="$3" detail="${4:-}"
    if [ "$ok" -eq 0 ]; then
        printf "${GREEN}PASS${RESET}  #%-2s %s\n" "$num" "$desc"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RESET}  #%-2s %s%s\n" "$num" "$desc" "${detail:+ — $detail}"
        FAIL=$((FAIL + 1))
    fi
}

summary() {
    echo
    if [ "$FAIL" -eq 0 ]; then
        printf "${GREEN}All %d checks passed.${RESET}\n" "$PASS"
        exit 0
    else
        printf "${RED}%d passed, %d FAILED.${RESET}\n" "$PASS" "$FAIL"
        exit 1
    fi
}

########################################################################
# HOST MODE
########################################################################
if [ "${1:-}" = "--host" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "$script_dir/.." && pwd)"
    cd "$repo_root"

    ENGINE="${ENGINE:-$(sed -n 's/^ENGINE=//p' .env 2>/dev/null | tail -1)}"
    ENGINE="${ENGINE:-docker}"
    # Direct `scripts/doctor.sh --host` must behave like `make doctor`:
    # activate the dind profile when the docker toolchain is enabled, or
    # checks 22/23 fail against sidecars compose never started.
    if [ -z "${COMPOSE_PROFILES:-}" ]; then
        case ",$(sed -n 's/^TOOLCHAINS=//p' .env 2>/dev/null | tail -1)," in
            *,docker,*) export COMPOSE_PROFILES=docker ;;
        esac
    fi
    COMPOSE="$ENGINE compose"
    if [ "$ENGINE" = "podman" ]; then
        COMPOSE="$ENGINE compose -f docker-compose.yml -f compose.podman.yml"
        if [ -f docker-compose.override.yml ]; then
            COMPOSE="$COMPOSE -f docker-compose.override.yml"
        fi
    fi

    if [ ! -f .env ]; then
        echo "doctor: .env is missing — copy .env.example to .env and set PROJECTS_DIR." >&2
        exit 1
    fi
    # Tolerate quoted values — compose strips quotes, so must we.
    PROJECTS_DIR="$(sed -n 's/^PROJECTS_DIR=//p' .env | tail -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")"

    echo "=== Container-side checks (1-10, 12-14, 16-19, + enabled toolchains) ==="
    $COMPOSE run --rm claude-code doctor
    container_rc=$?
    echo
    echo "=== Host-side checks (11, 15) ==="

    # --- 11: file created in /workspace is owned by the host user ---------
    marker=".doctor-owner-test-$$"
    $COMPOSE run --rm --no-deps -T claude-code bash -c "touch /workspace/$marker" >/dev/null 2>&1
    if [ -e "$PROJECTS_DIR/$marker" ]; then
        owner_uid="$(stat -c '%u' "$PROJECTS_DIR/$marker")"
        [ "$owner_uid" = "$(id -u)" ]
        report 11 $? "workspace file owned by host user" "owner uid=$owner_uid, expected $(id -u)"
        rm -f "$PROJECTS_DIR/$marker"
    else
        report 11 1 "workspace file owned by host user" "file not visible on host at $PROJECTS_DIR/$marker"
    fi

    # --- 15: empty secrets dir -> host-side auto-provisioning -------------
    tmpd="$(mktemp -d)"
    out="$(SIGNING_DIR="$tmpd/git-signing" NONINTERACTIVE=1 scripts/ensure-signing-key.sh 2>&1)"
    ok=1
    if [ -f "$tmpd/git-signing/signing_key" ] \
        && [ -f "$tmpd/git-signing/allowed_signers" ] \
        && [ -f "$tmpd/git-signing/key.meta" ] \
        && printf '%s' "$out" | grep -q 'ssh-ed25519' \
        && [ "$(jq -r .created_at "$tmpd/git-signing/key.meta")" != "null" ]; then
        ok=0
    fi
    report 15 $ok "empty secrets/ triggers host-side key provisioning + pubkey display"
    chmod -R u+w "$tmpd" && rm -rf "$tmpd"

    # Informational, never affects the check results: old images left behind
    # by rebuilds (e.g. after the update-image skill) linger as dangling.
    # Count only images prune can actually reclaim — dangling images still
    # referenced by a container (e.g. a long-running sandbox session on a
    # superseded image) are kept by prune and would nag forever.
    used="$($ENGINE ps -aq 2>/dev/null | xargs -r "$ENGINE" container inspect --format '{{.Image}}' 2>/dev/null)"
    reclaimable=0
    for id in $($ENGINE images -q -f dangling=true 2>/dev/null); do
        case "$used" in
            *"$id"*) ;;
            *) reclaimable=$((reclaimable + 1)) ;;
        esac
    done
    if [ "$reclaimable" -gt 0 ]; then
        echo
        echo "note: $reclaimable dangling image(s) from previous builds — run 'make prune' to reclaim disk space."
    fi

    echo
    if [ "$container_rc" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
        printf '%bdoctor: all host and container checks passed.%b\n' "$GREEN" "$RESET"
        exit 0
    fi
    printf '%bdoctor: FAILURES detected (container rc=%s, host fails=%s).%b\n' "$RED" "$container_rc" "$FAIL" "$RESET"
    exit 1
fi

########################################################################
# CONTAINER MODE
########################################################################

WORK="$(mktemp -d /tmp/doctor.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --- 1: not root ----------------------------------------------------------
[ "$(id -u)" -ne 0 ]
report 1 $? "container user is not root (uid=$(id -u))"

# --- 2: no capabilities ---------------------------------------------------
capeff="$(awk '/^CapEff:/ {print $2}' /proc/self/status)"
[ "$capeff" = "0000000000000000" ]
report 2 $? "effective capability set is empty" "CapEff=$capeff"

# --- 3: rootfs read-only --------------------------------------------------
! touch /etc/.doctor-rwtest 2>/dev/null
report 3 $? "write to /etc fails (read-only rootfs)"

# --- 4: no auth key material anywhere -------------------------------------
found="$(find /home /root /etc /run -maxdepth 6 \
    \( -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'id_ecdsa*' \
       -o -name 'id_dsa*' -o -name '*.pem' \) -type f 2>/dev/null; \
    find "$HOME/.ssh" -type f 2>/dev/null)"
[ -z "$found" ]
report 4 $? "no SSH auth keys / PEM files in the container" "$found"

# --- 5: no docker socket --------------------------------------------------
[ ! -e /var/run/docker.sock ]
report 5 $? "/var/run/docker.sock is absent"

# --- 6: non-allowlisted egress blocked ------------------------------------
curl -sS -m 15 -o /dev/null https://example.com 2>"$WORK/curl6.err"
[ $? -ne 0 ]
report 6 $? "https://example.com is blocked by the egress proxy"

# --- 7: api.anthropic.com reachable ---------------------------------------
# Up to 3 attempts: under load, WSL2/NAT can time out individual upstream
# connects (proxy 503 after connect_timeout) while parallel tunnels to the
# same host succeed. One flaky CONNECT must not fail the suite; persistent
# unreachability still does.
code="000"
for _ in 1 2 3; do
    code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' https://api.anthropic.com/ 2>"$WORK/curl7.err")"
    [ -n "$code" ] && [ "$code" != "000" ] && break
done
[ -n "$code" ] && [ "$code" != "000" ]
report 7 $? "https://api.anthropic.com is reachable via proxy" "http_code=$code $(cat "$WORK/curl7.err" 2>/dev/null | head -1)"

# --- helper: throwaway repo ----------------------------------------------
new_repo() {
    local d="$1"
    mkdir -p "$d" && cd "$d" || return 1
    git init -q .
    echo test > file.txt
    git add file.txt
}

# --- 8: git network subcommands blocked -----------------------------------
new_repo "$WORK/net-repo" >/dev/null 2>&1
ok=0
for sub in "push" "fetch" "pull"; do
    out="$(git $sub 2>&1)"
    rc=$?
    if [ $rc -eq 0 ] || ! printf '%s' "$out" | grep -q 'HOST ACTION REQUIRED'; then
        ok=1
    fi
done
out="$(cd /tmp && git clone https://example.com/x.git 2>&1)"
{ [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'HOST ACTION REQUIRED'; } || ok=1
report 8 $ok "git push/fetch/pull/clone blocked with host instructions"

# --- 9: Co-Authored-By commit rejected ------------------------------------
cd "$WORK/net-repo"
git commit -q -m "$(printf 'chore: doctor test\n\nCo-Authored-By: Claude <noreply@anthropic.com>')" 2>"$WORK/hook9.err"
[ $? -ne 0 ]
report 9 $? "commit with Co-Authored-By trailer rejected by commit-msg hook"

# --- 10: regular commit succeeds with a valid signature -------------------
git commit -q -m "test: doctor signing verification" 2>"$WORK/hook10.err"
rc=$?
sig="$(git log -1 --show-signature 2>&1)"
{ [ $rc -eq 0 ] && printf '%s' "$sig" | grep -q 'Good "git" signature'; }
report 10 $? "regular commit succeeds and signature verifies" "$(printf '%s' "$sig" | head -3 | tr '\n' ' ')"

# --- 12: writes outside /workspace, /tmp, ~/.claude fail ------------------
ok=0
for p in /usr/.rwtest /opt/.rwtest /home/dev/.rwtest /var/.rwtest; do
    if touch "$p" 2>/dev/null; then rm -f "$p"; ok=1; fi
done
# and the allowed ones must work:
for p in /workspace/.doctor-rwtest /tmp/.doctor-rwtest "$HOME/.claude/.doctor-rwtest"; do
    if ! touch "$p" 2>/dev/null; then ok=1; else rm -f "$p"; fi
done
report 12 $ok "only /workspace, /tmp and ~/.claude are writable"

# --- 13: signing mount read-only ------------------------------------------
! touch /run/secrets/git-signing/.doctor-rwtest 2>/dev/null
report 13 $? "/run/secrets/git-signing/ is read-only"

# --- 14: signing key not under /workspace ---------------------------------
real="$(realpath /run/secrets/git-signing 2>/dev/null || echo /run/secrets/git-signing)"
cfg="$(git config --global user.signingkey)"
{ [ "${real#/workspace}" = "$real" ] && [ "${cfg#/workspace}" = "$cfg" ]; }
report 14 $? "signing key lives outside /workspace" "mount=$real key=$cfg"

# --- 16/17: key-age fixtures ----------------------------------------------
make-fixtures "$WORK/fixtures"

# 16: 31 days -> warn block, commit proceeds
out="$(KEY_META_PATH="$WORK/fixtures/warn/key.meta" KEY_AGE_MARKER="$WORK/marker16" \
    bash /opt/git-hooks/pre-commit 2>&1)"
rc=$?
{ [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'ROTATION DUE'; }
report 16 $? "31-day-old key: warning shown, commit allowed"

# 17: 46 days -> pre-commit aborts with rotation instructions
out="$(KEY_META_PATH="$WORK/fixtures/expired/key.meta" KEY_AGE_MARKER="$WORK/marker17" \
    bash /opt/git-hooks/pre-commit 2>&1)"
rc=$?
{ [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'rotate-signing-key'; }
report 17 $? "46-day-old key: pre-commit aborts with rotation instructions"

# --- 18: rotated key — old AND new signatures verify ----------------------
rot="$WORK/rotation"
mkdir -p "$rot"
ssh-keygen -q -t ed25519 -N "" -C old -f "$rot/old_key"
ssh-keygen -q -t ed25519 -N "" -C new -f "$rot/new_key"
t_start="$(date -u -d '90 days ago' +%Y%m%d%H%M%SZ)"
t_rot="$(date -u -d '10 days ago' +%Y%m%d%H%M%SZ)"
{
    printf 'doctor@test valid-after="%s",valid-before="%s" %s old\n' \
        "$t_start" "$t_rot" "$(cut -d' ' -f1-2 "$rot/old_key.pub")"
    printf 'doctor@test valid-after="%s" %s new\n' \
        "$t_rot" "$(cut -d' ' -f1-2 "$rot/new_key.pub")"
} > "$rot/allowed_signers"

new_repo "$rot/repo" >/dev/null 2>&1
git_rot() {
    git -c user.email=doctor@test -c user.name=doctor \
        -c gpg.ssh.allowedSignersFile="$rot/allowed_signers" "$@"
}
old_date="$(date -u -d '20 days ago' -Is)"
GIT_AUTHOR_DATE="$old_date" GIT_COMMITTER_DATE="$old_date" \
    git_rot -c user.signingkey="$rot/old_key" commit -q -m "test: commit signed with old key" 2>"$WORK/rot1.err"
rc1=$?
echo more >> file.txt && git add file.txt
git_rot -c user.signingkey="$rot/new_key" commit -q -m "test: commit signed with new key" 2>"$WORK/rot2.err"
rc2=$?
good_count="$(git_rot log --show-signature 2>&1 | grep -c 'Good "git" signature')"
{ [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ "$good_count" -eq 2 ]; }
report 18 $? "after rotation, old AND new commit signatures verify" "good signatures: $good_count/2 $(cat "$WORK/rot1.err" "$WORK/rot2.err" 2>/dev/null | head -1)"

# --- 19: blocked-domains reports the domain denied in check 6 -------------
# Depends on check 6 having already sent a (denied) https://example.com
# request through the proxy earlier in this run.
out="$(blocked-domains 2>&1)"
{ printf '%s' "$out" | grep -q 'example\.com' \
    && printf '%s' "$out" | grep -q 'HOST ACTION REQUIRED'; }
report 19 $? "blocked-domains lists proxy-denied domains with host instructions"

# --- 20/21: toolchain function tests --------------------------------------
# Keyed on SANDBOX_TOOLCHAINS (set by compose from TOOLCHAINS) — the same
# variable that selected the image toolchains AND the proxy's allowlist
# fragments, so each enabled toolchain and its registry must both work.
# Binary sniffing would misfire: python3/pip ship in the base tooling too.
case ",${SANDBOX_TOOLCHAINS:-}," in *,php,*)
    ver="$(COMPOSER_HOME=/tmp/doctor-composer composer --version 2>/dev/null)"
    code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' https://repo.packagist.org/packages.json 2>"$WORK/curl20.err")"
    { [ -n "$ver" ] && [ "$code" = "200" ]; }
    report 20 $? "php toolchain: composer runs and packagist is reachable" "http_code=$code $(head -1 "$WORK/curl20.err" 2>/dev/null)"
    ;;
esac
case ",${SANDBOX_TOOLCHAINS:-}," in *,python,*)
    ver="$(python3 --version 2>/dev/null)"
    code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -I https://pypi.org/simple/pip/ 2>"$WORK/curl21.err")"
    { [ -n "$ver" ] && [ "$code" = "200" ]; }
    report 21 $? "python toolchain: python runs and PyPI is reachable" "http_code=$code $(head -1 "$WORK/curl21.err" 2>/dev/null)"
    ;;
esac
case ",${SANDBOX_TOOLCHAINS:-}," in *,docker,*)
    # The dind sidecar may still be starting — retry the daemon probe.
    ok=1
    for _ in 1 2 3 4 5 6; do
        if docker version >/dev/null 2>&1; then ok=0; break; fi
        sleep 5
    done
    if [ "$ok" -eq 0 ]; then
        # End-to-end: pull through the egress proxy + run in the sidecar.
        out="$(docker run --rm hello-world 2>&1)"
        printf '%s' "$out" | grep -q "Hello from Docker" || ok=1
    fi
    report 22 $ok "docker toolchain: dind reachable, pull+run via proxy works" "$(printf '%s' "${out:-daemon unreachable}" | head -1)"

    # --- 23: image pull control -------------------------------------------
    # Non-allowlisted pulls must be denied by dind-guard, and the raw
    # daemon must not be reachable (it lives on the isolated dind-net;
    # "dind" is only a guard alias that doesn't expose 2375).
    ok=0
    docker pull alpine >/dev/null 2>&1 && ok=1
    docker rmi alpine >/dev/null 2>&1 && ok=1   # must not exist either way
    docker -H tcp://dind:2375 version >/dev/null 2>&1 && ok=1
    docker -H tcp://dind-daemon:2375 version >/dev/null 2>&1 && ok=1
    report 23 $ok "dind-guard denies non-allowlisted image pulls and raw API access"
    ;;
esac

cd /
summary
