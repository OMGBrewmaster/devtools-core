# Secrets in GitHub Actions Workflows

How to safely reference `secrets.*` values in GitHub Actions workflows without
shell injection or log leakage. Read this when writing or reviewing workflow
`run:` blocks that use secrets.

## Rule

**Never interpolate `${{ secrets.* }}` directly inside a `run:` block.** Always pass secrets through an `env:` block first, then reference the environment variable in the shell script.

## Why

GitHub Actions expression syntax (`${{ }}`) performs **text substitution before the shell sees the command**. If a secret contains shell metacharacters — single quotes, backticks, `$()`, newlines — the resulting command can:

- **Break** with a syntax error, leaking partial secret content to logs
- **Execute attacker-controlled commands** if the secret value is ever influenced by external input

Passing the value through `env:` lets the Actions runtime set a proper environment variable that the shell reads safely, regardless of the value's content.

## Correct pattern

Pass the secret to `env:` on the step (or job), then use the variable name in the shell:

```yaml
- name: Write Google Play credentials
  env:
    GOOGLE_PLAY_SERVICE_ACCOUNT_KEY: ${{ secrets.GOOGLE_PLAY_SERVICE_ACCOUNT_KEY }}
  run: echo "$GOOGLE_PLAY_SERVICE_ACCOUNT_KEY" > "$RUNNER_TEMP/play-key.json"
```

If many steps in the same job need the same secret, set it once at the **job level**:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    env:
      AWS_PROJECT_ARN: ${{ secrets.AWS_DEVICE_FARM_PROJECT_ARN }}
    steps:
      - name: Step A
        run: aws devicefarm create-upload --project-arn "$AWS_PROJECT_ARN" ...
      - name: Step B
        run: aws devicefarm schedule-run --project-arn "$AWS_PROJECT_ARN" ...
```

## Wrong patterns

Direct interpolation in `run:` — breaks if the value contains `'`:

```yaml
# BAD
run: echo '${{ secrets.SERVICE_ACCOUNT_KEY }}' > key.json
```

Direct interpolation in `run:` — breaks if the value contains `"`, `` ` ``, or `$`:

```yaml
# BAD
run: echo "${{ secrets.SERVICE_ACCOUNT_KEY }}" > key.json
```

Assignment in shell — same problem, just moves the substitution one step to the right:

```yaml
# BAD
run: |
  project_arn="${{ secrets.AWS_PROJECT_ARN }}"
  aws devicefarm create-upload --project-arn "$project_arn"
```

## Where `${{ secrets.* }}` is safe

These contexts are **not** shell scripts, so direct interpolation is fine:

| Context | Example |
|---------|---------|
| `env:` blocks | `env: KEY: ${{ secrets.X }}` |
| `with:` inputs to actions | `with: credentials_json: ${{ secrets.X }}` |
| `if:` conditionals | `if: ${{ secrets.X != '' }}` |

## Quick audit

Find violations with:

```sh
grep -n 'secrets\.' .github/workflows/*.yml | grep -v '^\s*#' | grep -v 'env:' | grep -v 'with:' | grep -v 'if:' | grep -v 'secrets:'
```

Every match should be in an `env:`, `with:`, `if:`, or secret declaration line — anything in a `run:` block is a violation.
