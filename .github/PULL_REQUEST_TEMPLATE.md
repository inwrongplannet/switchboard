<!--
Thanks for the PR. Keep this short — a couple of sentences per section is plenty.
Delete any section that genuinely does not apply.
-->

## What this changes

<!-- One or two sentences. What is different after this merges? -->

## Why

<!-- The problem this solves. Link the issue if there is one: Fixes #123 -->

## How it was verified

<!-- Not "tests pass" — what did you actually check? -->

- [ ] `pytest` is green locally
- [ ] Added or updated tests covering the change
- [ ] Ran the affected path by hand (say which, below)

<!-- If this touches the semantic cache, key rotation, or auth, say what you ran: -->

## Checklist

- [ ] I agree my contribution is licensed under the [MIT License](../LICENSE)
- [ ] No secrets, API keys, or `.env` contents in the diff
- [ ] Any nearby ASCII diagram is still accurate, or was updated
- [ ] If I edited `site/docs.html`, I made the matching change in `README.md`
- [ ] New tests needing live credentials are marked `@pytest.mark.integration`

## Anything you are unsure about

<!-- Optional. A question here gets a faster review than a perfect PR with no context. -->
