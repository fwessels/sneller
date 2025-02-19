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

package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"log"
	"os"
	"regexp"
)

type opcode struct {
	name   string
	offset int64
}

func parseAsmFile(path string) ([]opcode, error) {
	f, err := os.Open(path)
	checkErr(err)
	defer f.Close()
	rd := bufio.NewReader(f)

	var ops []opcode
	re := regexp.MustCompile(`^TEXT bc(?P<op>.*)\(SB\)`)

	ofs := int64(0)
	for {
		raw, pre, err := rd.ReadLine()
		if err != nil {
			if err == io.EOF {
				break
			}
			return nil, err
		}
		if pre {
			return nil, fmt.Errorf("buffer not big enough to fit line beginning with %s", raw)
		}

		if !bytes.HasPrefix(raw, []byte("TEXT bc")) {
			continue
		}

		line := string(raw)
		if v := re.FindStringSubmatch(line); len(v) > 0 {
			ops = append(ops, opcode{name: v[1], offset: ofs})
			ofs += 8
		}
	}

	return ops, nil
}

const autogenerated = "// Code generated automatically; DO NOT EDIT"

func generateGoFile(name string, ops []opcode) {
	f, err := os.Create(name)
	checkErr(err)
	defer f.Close()

	writeLn(f, "package vm")
	writeLn(f, "")
	writeLn(f, autogenerated)
	writeLn(f, "")
	writeLn(f, "const (")

	for i := range ops {
		writeLn(f, fmt.Sprintf("\top%s bcop = %d", ops[i].name, i))
	}

	writeLn(f, fmt.Sprintf("\t%s = %d", "_maxbcop", len(ops)))
	writeLn(f, ")")
}

func generateAsmFile(name string, ops []opcode) {
	f, err := os.Create(name)
	checkErr(err)
	defer f.Close()

	writeLn(f, `#include "textflag.h"`)
	writeLn(f, "")
	writeLn(f, autogenerated)
	writeLn(f, "")

	const data = "opaddrs"
	const trap = "trap"

	for i := range ops {
		writeLn(f, fmt.Sprintf("DATA %s+0x%03x(SB)/8, $bc%s(SB)", data, ops[i].offset, ops[i].name))
	}

	offset := ops[len(ops)-1].offset
	n := nextPower(len(ops))
	for i := len(ops); i < n; i++ {
		offset += 8
		writeLn(f, fmt.Sprintf("DATA %s+0x%03x(SB)/8, $bc%s(SB)", data, offset, trap))
	}
	offset += 8

	writeLn(f, fmt.Sprintf("GLOBL %s(SB), RODATA|NOPTR, $0x%04x", data, offset))
}

func generateAsmHeader(name string, ops []opcode) {
	f, err := os.Create(name)
	checkErr(err)
	defer f.Close()

	mask := nextPower(len(ops)) - 1

	writeLn(f, autogenerated)
	writeLn(f, fmt.Sprintf("#define OPMASK 0x%03x", mask))
}

func main() {
	ops, err := parseAsmFile("evalbc_amd64.s")
	checkErr(err)

	generateGoFile("ops_gen.go", ops)
	generateAsmFile("ops_gen_amd64.s", ops)
	generateAsmHeader("ops_mask.h", ops)
}

func checkErr(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

func writeLn(f *os.File, s string) {
	_, err := f.WriteString(s)
	checkErr(err)
	_, err = f.Write([]byte{'\n'})
	checkErr(err)
}

func nextPower(x int) int {
	n := 1
	for n < x {
		n *= 2
	}

	return n
}
