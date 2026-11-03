## Style Guidelines

Style is about how code looks on the page, in any language. Each
language guide carries the worked examples in that language's syntax;
these are the rules those examples demonstrate.

- Symmetry is king. If you take an approach in a section of code, apply
  it universally.
- Break a long line at a logical point — after the function name,
  between arguments — rather than at whatever column it ran out at.
- Don't let one line stick out from a block of shorter lines. Long
  lines are fine so long as ALL the lines are long.
- Prefer reducing a call's line span to aligning its continuations far
  to the right. Arguments on their own lines at a uniform indent beat
  arguments aligned under the first one, which goes jagged the moment
  the function name changes length.
- A short function inlines its arguments. Arguments go on the next line
  once there is a docstring or a type annotation above them.
- Extract into a named binding an expression too long for one line, rather
  than wrapping it where it stands.
- Where one binding in a group is long enough to need its own line, put
  every binding in that group on its own line. Symmetry decides the
  whole group, not each binding separately.
