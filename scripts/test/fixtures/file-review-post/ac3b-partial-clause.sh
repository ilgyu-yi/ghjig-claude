#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # wrapper-fragment fixture: $sf/$frdir/mt1/mt2 are assigned by the real ghjig_file_review_post.sh this mimics; §148h-p4 greps this file as TEXT and never executes it.
# AC3b fixture (#655) — RED side of the per-site honest-mistake predicate.
#
# A NON-EXEMPT honest-mistake arm (`mtime-unresolvable`) with TWO deny sites:
# the first carries the em-dash recovery clause, the second is BARE. Because the
# arm is not twin-exempt, the predicate requires EVERY one of its sites to carry
# the clause, so this fixture MUST red. It proves the per-site check is live — a
# match-once-per-arm-name predicate would have gone green on the clause-bearing
# first site and never seen the bare second one.
mt1=$(fr_mtime "$sf") || deny mtime-unresolvable "could not read the staging file mtime ($sf) — install a stat exposing -c/-f and re-invoke"
mt2=$(fr_mtime "$sf") || deny mtime-unresolvable "could not re-read the staging file mtime ($sf)"
