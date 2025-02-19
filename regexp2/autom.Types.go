// Copyright (C) 2022 Sneller, Inc.
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

package regexp2

import (
	"unicode/utf8"
)

// escapeChar is the rune used as the escape character.
const escapeChar = rune(0x5C) // backslash

// nodeIDT type of nodes in NFA/DFA
type nodeIDT int32

// stateIDT type of states in DFA data-structures
type stateIDT int32

// groupIDT type of observation groups
type groupIDT int

const edgeEpsilonRune = rune(utf8.MaxRune)
const edgeAnyRune = rune(utf8.MaxRune + 1)
const edgeAnyNotLfRune = rune(utf8.MaxRune + 2)
const edgeRLZARune = rune(utf8.MaxRune + 3)
const edgeLfRune = rune('\n')
