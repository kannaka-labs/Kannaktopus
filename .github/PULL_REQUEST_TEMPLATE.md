## Description
Brief description of changes.

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Documentation update
- [ ] Refactoring
- [ ] Other (describe):

## Checklist
- [ ] Code passes `bash -n scripts/orchestrate.sh`
- [ ] Shell scripts pass `bash -n` syntax check
- [ ] Tests pass: `bash tests/unit/test-openclaw-compat.sh`
- [ ] New skills/commands registered in `.claude-plugin/plugin.json`
- [ ] Version bump (if releasing): package.json + plugin.json + marketplace.json + README.md + CHANGELOG.md
- [ ] Documentation updated (if applicable)
- [ ] CHANGELOG.md updated (for features/fixes)

## Testing
How was this tested? Which test suites were run?

```bash
# Run pre-push suite
bash tests/run-pre-push.sh

# Run specific test
bash tests/unit/test-<name>.sh
```

## Related Issues
Closes #
