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

/*
Alternative to-{upper,lower} approach
--------------------------------------------------

# Overally the design is strighforward

1. We consider only characters in range 0..1ffff --- it is 17 bits.
2. We split the char code into two parts: lower 8 bits (col), and higher 9 bits (row).
3. Then we lookup in the table like: lookup[row][col]. Thus, we derference twice.
4. Lookup might store either a difference of codes (2 bytes) or pre-encoded UTF-8 char (4 bytes).

The only trick with lookup is that we compress the second-level
table. Each entry of lookup[row] contains three values:

- the minimum col value
- the maximum col value
- offset in values table

Thus, the real lookup looks like this:

	if row > maxRow {
	    return no-change
	}

	entry := lookup[row]
	if col >= entry.lo && col <= entry.hi {
	    return values[col - entry.lo + entry.offset]
	}

For detailed implementation please see method `LookupDiff.translate below`.

Comparison with the current approach
--------------------------------------------------

The current approach stores only the difference of char codes.
As a result, we have to perform: 1) UTF-8 -> rune; 2) update
rune; 3) rune -> UTF-8.

This new approach allows us to omit the last step, as we can
precompute UTF-8 results.

Lookup tables size comparison:

* to-lower: current =  9665, new = 12892
* to upper: current = 10356, new = 13260

The tables are ~30% bigger.
*/
package main

import (
	"fmt"
	"log"
	"os"
	"strings"
	"unicode/utf8"
)

func main() {
	input := []struct {
		fn   func(string) string
		name string
	}{
		{
			fn:   strings.ToLower,
			name: "tolower",
		},
		{
			fn:   strings.ToUpper,
			name: "toupper",
		},
	}

	for i := range input {
		buckets := build(input[i].fn)
		ld := assembleStructure(buckets)
		checkErr(ld.validate(input[i].fn))
		fmt.Printf("%s lookup size: %d bytes\n", input[i].name, ld.size())

		f, err := os.Create(fmt.Sprintf("bc_constant_%s.h", input[i].name))
		checkErr(err)
		writeAsmDefinitions(f, ld, input[i].name)
		f.Close()
	}
}

const (
	totalBits  = 17
	tableBits  = 8
	tableSize  = 1 << tableBits
	tableMask  = tableSize - 1
	lookupBits = totalBits - tableBits
	lookupSize = 1 << lookupBits
	lookupMask = lookupSize - 1
)

type Bucket struct {
	values [tableSize]int32
}

func NewBucket() *Bucket {
	return &Bucket{}
}

func (b *Bucket) set(index uint32, diff int32) {
	if b.values[index] != 0 && b.values[index] != diff {
		panic(fmt.Sprintf("wrong code %d => %d", b.values[index], diff))
	}
	b.values[index] = diff
}

func (b *Bucket) First() int {
	for i := range b.values {
		if b.values[i] != 0 {
			return i
		}
	}

	return -1
}

func (b *Bucket) Last() int {
	last := -1
	for i := range b.values {
		if b.values[i] != 0 {
			last = i
		}
	}

	return last
}

func (b *Bucket) empty() bool {
	return b.First() == -1
}

func (b *Bucket) size() int {
	f := b.First()
	if f == -1 {
		return 0
	}

	l := b.Last()
	return l - f + 1
}

func build(fn func(string) string) map[uint32]*Bucket {
	buckets := make(map[uint32]*Bucket)
	for r := rune(0); r < rune(0x1ffff); r++ {
		if !utf8.ValidRune(r) {
			continue
		}
		s := string(r)
		l := fn(s)

		r2, _ := utf8.DecodeRuneInString(l)
		diff := int32(r2) - int32(r)
		if diff == 0 {
			continue
		}

		row := uint32(r) >> tableBits
		col := uint32(r) & tableMask
		bucket, ok := buckets[row]
		if ok {
			bucket.set(col, diff)
		} else {
			bucket = NewBucket()
			bucket.set(col, diff)
			buckets[row] = bucket
		}
	}

	return buckets
}

type LookupItem struct {
	offset uint32
	lo, hi uint16
}

type LookupDiff struct {
	lookup [lookupSize]LookupItem
	values []int32
}

func (ld *LookupDiff) transform(r rune) rune {
	v := uint32(r)

	row := v >> tableBits
	if row > lookupMask {
		return r
	}

	lo := uint32(ld.lookup[row].lo)
	hi := uint32(ld.lookup[row].hi)
	offset := ld.lookup[row].offset

	col := v & tableMask
	if !(col >= lo && col <= hi) {
		return r
	}

	idx := offset + col - lo

	return r + rune(ld.values[idx])
}

func (ld *LookupDiff) size() int {
	return (len(ld.lookup) + len(ld.values)) * 4
}

func (ld *LookupDiff) validate(fn func(string) string) error {
	var err error
	for r := rune(0); r < rune(0x1ffff); r++ {
		if !utf8.ValidRune(r) {
			continue
		}
		t := fn(string(r))
		want, _ := utf8.DecodeRuneInString(t)
		got := ld.transform(r)

		if want != got {
			fmt.Printf("input: %d, want = %x, got = %x\n", r, want, got)
			err = fmt.Errorf("failed")
		}
	}

	return err
}

func assembleStructure(buckets map[uint32]*Bucket) *LookupDiff {
	ld := LookupDiff{}
	offset := 0
	for i := 0; i < lookupSize; i++ {
		v := buckets[uint32(i)]
		if v == nil {
			// create wrong range, thanks to that we don't have
			// to have an extra check for empty entries
			ld.lookup[i].lo = 255
			ld.lookup[i].hi = 0
			continue
		}
		if !v.empty() {
			ld.lookup[i].lo = uint16(v.First())
			ld.lookup[i].hi = uint16(v.Last())
			ld.lookup[i].offset = uint32(offset)
			offset += v.size()
		}
	}

	totalSize := offset

	ld.values = make([]int32, 0, totalSize)

	for i := 0; i < lookupSize; i++ {
		v := buckets[uint32(i)]
		if v == nil || v.empty() {
			continue
		}
		f := ld.lookup[i].lo
		l := ld.lookup[i].hi
		ld.values = append(ld.values, v.values[f:l+1]...)
	}

	return &ld
}

const autogenerated = "// Code generated automatically; DO NOT EDIT"

func writeAsmDefinitions(f *os.File, ld *LookupDiff, kind string) {
	offset := 0
	name := fmt.Sprintf("str_%s_lookup", kind)

	emitU8 := func(v uint8) {
		writeLn(f, "DATA %s<>+(%d)(SB)/1, $0x%02x", name, offset, v)
		offset += 1
	}

	emitU16 := func(v uint16) {
		writeLn(f, "DATA %s<>+(%d)(SB)/2, $0x%04x", name, offset, v)
		offset += 2
	}

	emitU32 := func(v uint32) {
		writeLn(f, "DATA %s<>+(%d)(SB)/4, $0x%08x", name, offset, v)
		offset += 4
	}

	emitSymbol := func() {
		writeLn(f, "GLOBL %s<>(SB), RODATA|NOPTR, $0x%04x", name, offset)
	}

	writeLn(f, autogenerated)
	writeLn(f, "")
	writeLn(f, "// lookup table for higer bits")
	offset = 0
	for i := range ld.lookup {
		if ld.lookup[i].lo > 255 {
			panic("`lo` can't fit in a byte")
		}
		if ld.lookup[i].hi > 255 {
			panic("`hi` can't fit in a byte")
		}
		if ld.lookup[i].offset > 65535 {
			panic("`offset` can't fit in a word")
		}
		emitU8(uint8(ld.lookup[i].lo))
		emitU8(uint8(ld.lookup[i].hi))
		emitU16(uint16(ld.lookup[i].offset))
	}

	emitSymbol()

	offset = 0
	writeLn(f, "// lookup table")
	name = fmt.Sprintf("str_%s_data", kind)
	// convert to UTF-8
	for i := range ld.lookup {
		lo := uint32(ld.lookup[i].lo)
		hi := uint32(ld.lookup[i].hi)
		for j := lo; j <= hi; j++ {
			r := int32(j) + int32(i<<tableBits)

			ofs := j - lo + ld.lookup[i].offset
			diff := ld.values[ofs]
			r += diff

			s := string(r)
			var w uint32
			switch len(s) {
			case 1:
				w = uint32(s[0])
			case 2:
				w = uint32(s[0]) | (uint32(s[1]) << 8)
			case 3:
				w = uint32(s[0]) | (uint32(s[1]) << 8) | (uint32(s[2]) << 16)
			case 4:
				w = uint32(s[0]) | (uint32(s[1]) << 8) | (uint32(s[2]) << 16) | (uint32(s[3]) << 24)
			default:
				panic("internal bug")
			}

			emitU32(w)
		}
	}

	emitSymbol()
}

func writeLn(f *os.File, s string, args ...interface{}) {
	_, err := fmt.Fprintf(f, s+"\n", args...)
	checkErr(err)
}

func checkErr(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
