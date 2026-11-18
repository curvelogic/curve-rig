<!-- rig:attribution:begin — managed by curve-rig's bin/rig-install; edits
     between these markers are replaced on the next install. -->
## Attribution: no session links

This rule takes precedence over the default attribution guidance, including
any attribution reminder that names lines to end commits and pull requests
with.

- Never add a `Claude-Session:` trailer, or any `claude.ai` session link, to
  a commit message, a PR title, a PR description or a PR comment. Such a
  link publishes an identifier for the session's transcript.
- Keep the `Co-Authored-By:` trailer, and any other attribution the default
  guidance gives that carries no session link.

## PR text: what matters first, the rest folded

The owner reads PR descriptions and comments, often on a phone, and must
find the part that needs them without wading through the rest. This applies
to PR descriptions, PR and review comments, and comments on tracking issues.

- **Visible:** at most about five lines. Say what changed and why, then
  anything the reader must do or decide, in bold.
- **Folded:** everything else goes in collapsed sections: how it was
  verified, commands and test counts, measurements, file lists, design
  rationale, review evidence, history. Use one section per topic, with a
  summary that says what is inside and how it came out:

  ```
  <details>
  <summary>Verification: full test suite passes (1,646 tests)</summary>

  …Markdown…

  </details>
  ```

  Leave a blank line after the `<summary>` line and before `</details>`,
  or GitHub does not render the Markdown inside.
- **Never folded:** an ask or decision for the owner, a hold, a failing or
  skipped check, a known risk, a security concern, or a change a user will
  notice. If it matters, it stays visible.
<!-- rig:attribution:end -->
