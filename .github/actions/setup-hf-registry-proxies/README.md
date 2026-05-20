# setup-hf-registry-proxies

Points the current job at HuggingFace's internal package registry
proxies (cargo, pip/uv, npm/pnpm/yarn, conda, go), which hide package
versions younger than 3 days to defend against supply-chain attacks.

Must run on a self-hosted in-VPC runner (e.g.
`runs-on: { group: aws-general-8-plus }`).

Script from https://registries.huggingface.tech/setup.sh.

## Usage

```yaml
- uses: huggingface/hf-workflows/.github/actions/setup-hf-registry-proxies@<sha>
```

Always pin `@<sha>`.
