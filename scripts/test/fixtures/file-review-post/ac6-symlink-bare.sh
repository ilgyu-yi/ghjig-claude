#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # wrapper-fragment fixture: $sf/$frdir/mt1/mt2 are assigned by the real ghjig_file_review_post.sh this mimics; §148h-p4 greps this file as TEXT and never executes it.
# AC6 fixture (#655) — GREEN side of the per-site honest-mistake predicate.
#
# Only the two symlink arms, both deliberately BARE. Symlink arms are hostile
# input, excluded from the §5.29 honest-mistake enumeration, and must never be
# swept into the recovery obligation. Running the predicate over this fixture
# must stay GREEN even though both arms are terse — the derived honest-mistake
# set contains neither symlink arm, so neither is ever iterated. If the predicate
# ever grew to sweep the symlink arms in, this fixture would red.
[ ! -L "$frdir" ] || deny symlink-dir "staging directory component is a symlink ($frdir)"
[ ! -L "$sf" ]    || deny symlink-leaf "staging file is a symlink ($sf)"
