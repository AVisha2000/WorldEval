# Shared WorldArena agent assets

This directory contains optional, agent-side planning aids that can be adopted
by more than one WorldArena game without changing the
`worldeval-agent/0.1.0` protocol.

Skills are declarative templates. They are never sent to a game as executable
commands. An agent must expand a selected skill into the ordinary actions
advertised by the active environment, and the resulting plan remains subject to
the normal observation, lease, precondition, receipt, and interruption rules.
