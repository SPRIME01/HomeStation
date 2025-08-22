You're getting "nope" because your .envrc contains Markdown code fences; direnv didn't execute the `export`. Remove the backticks and ensure the direnv hook is active.

Fix (zsh-friendly):

```sh
# remove Markdown fences from .envrc
sed -i '/^```/d' .envrc

# load direnv hook into current shell (and add to ~/.zshrc to persist)
eval "$(direnv hook zsh)" && printf 'eval "$(direnv hook zsh)"\n' >> ~/.zshrc

# allow the file and verify
direnv allow .
echo "${FOO-nope}"   # should print 'foo'
```

If that still prints "nope", open .envrc and confirm it contains exactly:
```sh
export FOO=foo
```
