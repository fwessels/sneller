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

package plan

import (
	"fmt"
	"strings"

	"github.com/SnellerInc/sneller/expr"
	"github.com/SnellerInc/sneller/ion"
)

type Input struct {
	// TODO: we should encode the underlying table
	// expr only so different bindings don't cause
	// the same table to be scanned multiple times
	Table  *expr.Table
	Handle TableHandle
}

func (i *Input) encode(dst *ion.Buffer, st *ion.Symtab, rw TableRewrite) error {
	dst.BeginStruct(-1)
	tbl, handle := i.Table, i.Handle
	if rw != nil {
		tbl, handle = rw(tbl, handle)
	}
	dst.BeginField(st.Intern("table"))
	tbl.Encode(dst, st)
	if handle != nil {
		dst.BeginField(st.Intern("handle"))
		err := handle.Encode(dst, st)
		if err != nil {
			return err
		}
	}
	dst.EndStruct()
	return nil
}

// A Tree is the root an executable query plan
// tree as well as the inputs for the plan.
//
// A Tree can be constructed with New
// or NewSplit and it can be executed
// with Exec or Transport.Exec.
type Tree struct {
	// Inputs are the tables to use as inputs to
	// the root of the plan tree.
	Inputs []Input
	// Root is the root node of the plan tree.
	Root Node
}

func tabify(n int, dst *strings.Builder) {
	for n > 0 {
		dst.WriteByte('\t')
		n--
	}
}

func tabfprintf(dst *strings.Builder, indent int, f string, args ...interface{}) {
	tabify(indent, dst)
	fmt.Fprintf(dst, f, args...)
}

func tabline(dst *strings.Builder, indent int, line string) {
	tabify(indent, dst)
	dst.WriteString(line)
	dst.WriteByte('\n')
}

func printops(dst *strings.Builder, indent int, op Op, in []Input) {
	if u, ok := op.(*UnionMap); ok {
		in = []Input{{Table: u.Orig}}
	}
	if from := op.input(); from != nil {
		printops(dst, indent, from, in)
	}
	if l, ok := op.(*Leaf); ok {
		tabline(dst, indent, l.describe(in))
		return
	}
	tabline(dst, indent, op.String())
}

func (t *Tree) describe(dst *strings.Builder) {
	t.Root.describe(0, dst, t.Inputs)
}

// String implements fmt.Stringer
func (t *Tree) String() string {
	var out strings.Builder
	t.describe(&out)
	return out.String()
}

// A Node is one node of a query plan tree and
// contains the operation sequence for one step
// of the plan, as well as links to subtrees
// this step of the plan depends on.
//
// Simple operations like filtering,
// aggregation, extended projection, etc.
// are grouped into sequences, and
// relational operations and sub-queries
// are handled by connecting their constituent
// subsequences together into a Node.
//
// (One motivating analogy might be that
// of basic blocks within a control flow graph,
// except that we restrict the vertices to
// form a tree rather than any directed graph.)
type Node struct {
	// OutputType is the type of
	// the output column(s) of the
	// sub-query produced by this tree.
	// Note that we cannot always infer
	// the output types of every query.
	// For example, 'SELECT * ...' on data
	// without a schema does not produce
	// a known ResultSet.
	OutputType ResultSet

	// Inputs are the tables to use as inputs to
	// the children of this plan tree node.
	Inputs []Input

	// Children is the list of sub-queries
	// that produce results that are prerequisites
	// to computing this query.
	Children []*Node

	// Op is the first element of a linked list
	// of query execution steps. The linked list
	// is encoded in reverse-execution-order, so
	// Op is the last step in execution order,
	// and the terminal element of the list
	// is the first in execution order.
	Op Op
}

func (n *Node) describe(indent int, dst *strings.Builder, in []Input) {
	for i := range n.Children {
		tabfprintf(dst, indent, "WITH REPLACEMENT(%d) AS (\n", i)
		n.Children[i].describe(indent+1, dst, n.Inputs)
		tabline(dst, indent, ")")
	}
	printops(dst, indent, n.Op, in)
}

// String implements fmt.Stringer
func (n *Node) String() string {
	var out strings.Builder
	n.describe(0, &out, nil)
	return out.String()
}
