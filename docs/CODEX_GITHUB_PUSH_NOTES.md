# Codex GitHub Push Notes

This note records the GitHub push method that worked from the Codex desktop
environment on Windows.

## Symptom

If another Codex window says:

```text
Failed to connect to github.com port 443
```

the failure is at the network layer. It is not a token problem yet.

## Working Method

Use Codex's bundled Git executable instead of relying on PATH:

```text
C:\Users\74450\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe
```

Run all GitHub network commands with escalated network permission:

```text
sandbox_permissions="require_escalated"
```

This applies to:

- `git clone`
- `git ls-remote`
- `git fetch`
- `git pull`
- `git push`

## Push With A Temporary GitHub Token

Do not put the token in the remote URL.
Do not rely on Git Credential Manager popups.

Use a temporary `GIT_ASKPASS` script and disable interactive prompts:

```powershell
$env:GITHUB_TOKEN = "<temporary fine-grained token>"
$askpass = Join-Path $env:TEMP "git-askpass-ombre.cmd"
$askpassContent = @'
@echo off
set prompt=%~1
echo %prompt% | findstr /I "Username" >nul
if %errorlevel%==0 (
  echo x-access-token
) else (
  echo %GITHUB_TOKEN%
)
'@
[System.IO.File]::WriteAllText($askpass, $askpassContent, [System.Text.ASCIIEncoding]::new())
$env:GIT_ASKPASS = $askpass
$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "never"

try {
  & "C:\Users\74450\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe" -c credential.helper= push origin main
} finally {
  Remove-Item -LiteralPath $askpass -Force -ErrorAction SilentlyContinue
  Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
  Remove-Item Env:\GIT_ASKPASS -ErrorAction SilentlyContinue
  Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
  Remove-Item Env:\GCM_INTERACTIVE -ErrorAction SilentlyContinue
}
```

After a successful push, delete the temporary GitHub token from GitHub.

## Quick Diagnosis

If `git push` fails with `Failed to connect to github.com port 443`, ask for
escalated network permission again. The shell cannot reach GitHub directly.

If GitHub rejects authentication after the network connection succeeds, then
check the token permissions. The token should be a fine-grained token for this
repository with:

```text
Contents: Read and write
```
