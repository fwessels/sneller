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

package vm

import (
	"io"
	"os"
	"testing"

	"github.com/SnellerInc/sneller/expr"
	"github.com/SnellerInc/sneller/ion"
)

func path(t testing.TB, s string) *expr.Path {
	p, err := expr.ParsePath(s)
	if err != nil {
		if t == nil {
			panic(err)
		}
		t.Helper()
		t.Fatal(err)
	}
	return p
}

func readVM(t testing.TB, name string) []byte {
	f, err := os.Open(name)
	if err != nil {
		t.Helper()
		t.Fatal(err)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		t.Helper()
		t.Fatal(err)
	}
	size := info.Size()
	if size > PageSize {
		t.Helper()
		t.Fatalf("file %q larger than page size", name)
	}
	buf := Malloc()
	t.Cleanup(func() { Free(buf) })
	_, err = io.ReadFull(f, buf[:size])
	if err != nil {
		t.Helper()
		t.Fatal(err)
	}
	return buf
}

func TestSplat(t *testing.T) {
	var bc bytecode
	var p prog
	var st ion.Symtab

	buf := readVM(t, "../testdata/parking3.ion")
	rest, err := st.Unmarshal(buf)
	if err != nil {
		t.Fatal(err)
	}

	delims := make([]vmref, 128)
	n, _ := scanvmm(rest, delims)
	if n != 60 {
		t.Fatalf("got %d rows at top level?", n)
	}

	p.Begin()
	field := p.Path("Entries")
	list := p.ssa2(stolist, field, field)
	p.Return(list)
	p.symbolize(&st, &auxbindings{})
	err = p.compile(&bc)
	if err != nil {
		t.Fatal(err)
	}

	// # of entries in the first
	// sixteen rows of the
	entrylengths := []int{
		15, 12, 3, 50,
		4, 8, 1, 70,
		14, 39, 5, 88,
		1, 2, 18, 1,
	}
	totalentries := 0
	for i := range entrylengths {
		totalentries += entrylengths[i]
	}

	outdelims := make([]vmref, 1024)
	outperm := make([]int32, len(outdelims))
	in, out := evalsplat(&bc, delims[:n], outdelims, outperm)
	if in != 16 {
		// we know we provided enough space
		// for all sixteen lanes to be
		// splatted
		t.Errorf("in: %d", in)
	}
	if out != totalentries {
		t.Errorf("out: %d, want %d", out, totalentries)
	}

	// test that the output permutation
	// is what we expect given the know
	// entry lengths
	j := 0
	for i := range entrylengths {
		span := entrylengths[i]
		for k := 0; k < span; k++ {
			if int(outperm[j+k]) != i {
				t.Errorf("outperm[%d]=%d, want %d", j+k, outperm[j+k], i)
			}
		}
		j += span
	}

	// test that delimiter object sizes
	// are sane
	for i := range outdelims[:out] {
		os, ds := objsize(vmref(outdelims[i]).mem())
		outsize := int(os) + int(ds)
		if outsize != int(outdelims[i][1]) {
			t.Errorf("delim %d: size %d, but computed %d", i, outdelims[i][1], outsize)
		}
	}

	// try consuming all the rows and
	// confirm that we get 1023 outputs
	total := 0
	delims = delims[:n]
	for len(delims) > 0 {
		in, out := evalsplat(&bc, delims, outdelims, outperm)
		if in > 16 {
			t.Errorf("consumed %d rows?", in)
		}
		if out > len(outdelims) {
			t.Errorf("output %d rows? (only space for %d)", out, len(outdelims))
		}
		total += out
		delims = delims[in:]
		outdelims = outdelims[out:]
		outperm = outperm[out:]
	}
	if total != 1023 {
		t.Errorf("splatted %d entries? (want 1023)", total)
	}
}
