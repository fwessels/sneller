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

package db

import (
	"bytes"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/SnellerInc/sneller/fsutil"
	"github.com/SnellerInc/sneller/ion/blockfmt"
)

func newDirFS(t *testing.T, dir string) *DirFS {
	dfs := NewDirFS(dir)
	var tmp bytes.Buffer
	// at the end of the test, validate every packfile
	t.Cleanup(func() {
		defer dfs.Close()
		walk := func(name string, file fs.File, err error) error {
			if err != nil {
				return err
			}
			defer file.Close()
			info, err := file.Stat()
			if err != nil {
				return err
			}
			trailer, err := blockfmt.ReadTrailer(file.(io.ReaderAt), info.Size())
			if err != nil {
				return err
			}
			tmp.Reset()
			blockfmt.Validate(file, trailer, &tmp)
			if tmp.Len() > 0 {
				t.Errorf("%s", tmp.Bytes())
			}
			return nil
		}
		err := fsutil.WalkGlob(dfs, "", "db/*/*/packed-*", walk)
		if err != nil {
			t.Error(err)
		}
	})
	dfs.Log = t.Logf
	dfs.MinPartSize = 32 * 1024 // pick a non-zero default
	return dfs
}

func fullScan(t *testing.T, b *Builder, who Tenant, db, table string, expect int) {
	total := 0
	for {
		n, err := b.Scan(who, db, table)
		if err != nil {
			if blockfmt.IsFatal(err) {
				fs, err := who.Root()
				if err != nil {
					t.Fatal(err)
				}
				idx, err := OpenIndex(fs, db, table, who.Key())
				if err != nil {
					t.Fatal(err)
				}
				if !idx.Scanning {
					t.Fatal("not scanning after error")
				}
				// should automatically recover
				continue
			}
			t.Helper()
			t.Fatal(err)
		}
		if n == 0 {
			break
		}
		total += n
	}
	if total != expect {
		t.Helper()
		t.Errorf("got %d instead of %d total scanned", total, expect)
	}
}

func noScan(t *testing.T, b *Builder, who *testTenant, db, table string) {
	who.ro = true
	fullScan(t, b, who, db, table, 0)
	who.ro = false
}

func TestScan(t *testing.T) {
	checkFiles(t)
	tmpdir := t.TempDir()
	for _, dir := range []string{
		filepath.Join(tmpdir, "b-prefix"),
	} {
		err := os.MkdirAll(dir, 0750)
		if err != nil {
			t.Fatal(err)
		}
	}

	dfs := newDirFS(t, tmpdir)
	err := WriteDefinition(dfs, "default", &Definition{
		Name: "taxi",
		Inputs: []Input{
			{Pattern: "file://b-prefix/*.block"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	newname := func(n int) string {
		return filepath.Join(tmpdir, "b-prefix", fmt.Sprintf("nyc-taxi%d.block", n))
	}
	oldname, err := filepath.Abs("../testdata/nyc-taxi.block")
	if err != nil {
		t.Fatal(err)
	}

	const objects = 10
	for i := 0; i < objects; i++ {
		err = os.Symlink(oldname, newname(i))
		if err != nil {
			t.Fatal(err)
		}
	}

	owner := newTenant(dfs)
	b := Builder{
		Align: 1024,
		Fallback: func(_ string) blockfmt.RowFormat {
			return blockfmt.UnsafeION()
		},
		Logf: t.Logf,
		// force re-scanning; we will only be
		// able to ingest two objects at once
		MaxScanBytes:  2 * 1024 * 1024,
		RangeMultiple: 4,

		GCLikelihood: 50,
		GCMinimumAge: 1 * time.Millisecond,
	}
	fullScan(t, &b, owner, "default", "taxi", objects)

	idx, err := OpenIndex(dfs, "default", "taxi", owner.Key())
	if err != nil {
		t.Fatal(err)
	}
	conf := GCConfig{Logf: t.Logf}
	err = conf.Run(dfs, "default", idx)
	if err != nil {
		t.Fatal(err)
	}
	if idx.Scanning {
		t.Error("index is still scanning?")
	}
	if idx.Objects() != 1 {
		t.Errorf("idx.Objects() = %d", idx.Objects())
	}
	idx.Inputs.Backing = dfs
	count := 0
	err = idx.Inputs.Walk("", func(name, etag string, id int) bool {
		if name != fmt.Sprintf("file://b-prefix/nyc-taxi%d.block", count) {
			t.Errorf("name = %s ?", name)
		}
		if id != 0 {
			t.Errorf("id(%s) = %d?", name, id)
		}
		count++
		return true
	})
	if err != nil {
		t.Fatal(err)
	}
	if count != objects {
		t.Fatalf("expected %d objects in input; got %d", objects, count)
	}
	noScan(t, &b, owner, "default", "taxi")
}

func TestScanPartitioned(t *testing.T) {
	checkFiles(t)
	tmpdir := t.TempDir()
	for _, dir := range []string{
		filepath.Join(tmpdir, "b-prefix"),
	} {
		err := os.MkdirAll(dir, 0750)
		if err != nil {
			t.Fatal(err)
		}
	}

	dfs := newDirFS(t, tmpdir)
	err := WriteDefinition(dfs, "default", &Definition{
		Name: "taxi",
		Inputs: []Input{
			{Pattern: "file://b-prefix/{part}/*.block"},
		},
		Partitions: []Partition{{
			Field: "part",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	partdir := func(p int) string {
		part := fmt.Sprintf("part-%d", p)
		return filepath.Join(tmpdir, "b-prefix", part)
	}
	newname := func(p, n int) string {
		part := fmt.Sprintf("part-%d", p)
		file := fmt.Sprintf("nyc-taxi%d.block", n)
		return filepath.Join(tmpdir, "b-prefix", part, file)
	}
	oldname, err := filepath.Abs("../testdata/nyc-taxi.block")
	if err != nil {
		t.Fatal(err)
	}

	const parts = 3
	const objects = 5
	for i := 0; i < parts; i++ {
		err := os.MkdirAll(partdir(i), 0750)
		if err != nil {
			t.Fatal(err)
		}
		for j := 0; j < objects; j++ {
			err = os.Symlink(oldname, newname(i, j))
			if err != nil {
				t.Fatal(err)
			}
		}
	}

	owner := newTenant(dfs)
	b := Builder{
		Align: 1024,
		Fallback: func(_ string) blockfmt.RowFormat {
			return blockfmt.UnsafeION()
		},
		Logf: t.Logf,
		// force re-scanning; we will only be
		// able to ingest two objects at once
		MaxScanBytes:  2 * 1024 * 1024,
		RangeMultiple: 4,

		GCLikelihood: 50,
		GCMinimumAge: 1 * time.Millisecond,
	}
	fullScan(t, &b, owner, "default", "taxi", parts*objects)

	idx, err := OpenIndex(dfs, "default", "taxi", owner.Key())
	if err != nil {
		t.Fatal(err)
	}
	conf := GCConfig{Logf: t.Logf}
	err = conf.Run(dfs, "default", idx)
	if err != nil {
		t.Fatal(err)
	}
	if idx.Scanning {
		t.Error("index is still scanning?")
	}
	if idx.Objects() != parts {
		t.Errorf("idx.Objects() = %d", idx.Objects())
	}
	idx.Inputs.Backing = dfs
	counts := make(map[int]int) // map[part]count
	err = idx.Inputs.Walk("", func(name, etag string, id int) bool {
		var part int
		_, err := fmt.Sscanf(name, "file://b-prefix/part-%d/", &part)
		if err != nil {
			t.Error(err)
			return true
		}
		count := counts[part]
		if name != fmt.Sprintf("file://b-prefix/part-%d/nyc-taxi%d.block", part, count) {
			t.Errorf("name = %s?", name)
		}
		counts[part] = count + 1
		if id != part {
			// this is a bit fragile in that it relies
			// on objects to be ingested in sorted
			// order, which is not guaranteed...
			t.Errorf("id(%s) = %d?", name, id)
		}
		count++
		return true
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(counts) != parts {
		t.Fatalf("expected %d partitions, got %d", parts, len(counts))
	}
	for part, count := range counts {
		if count != objects {
			t.Fatalf("part %d: expected %d objects in input; got %d", part, objects, count)
		}
	}
	noScan(t, &b, owner, "default", "taxi")
}

func TestNewIndexScan(t *testing.T) {
	checkFiles(t)
	tmpdir := t.TempDir()
	for _, dir := range []string{
		filepath.Join(tmpdir, "b-prefix"),
	} {
		err := os.MkdirAll(dir, 0750)
		if err != nil {
			t.Fatal(err)
		}
	}

	dfs := newDirFS(t, tmpdir)
	err := WriteDefinition(dfs, "default", &Definition{
		Name: "taxi",
		Inputs: []Input{
			{Pattern: "file://b-prefix/*.block"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	newname := func(n int) string {
		return filepath.Join(tmpdir, "b-prefix", fmt.Sprintf("nyc-taxi%d.block", n))
	}
	oldname, err := filepath.Abs("../testdata/nyc-taxi.block")
	if err != nil {
		t.Fatal(err)
	}

	const objects = 3
	for i := 0; i < objects; i++ {
		err = os.Symlink(oldname, newname(i))
		if err != nil {
			t.Fatal(err)
		}
	}

	owner := newTenant(dfs)
	b := Builder{
		Align: 1024,
		Fallback: func(_ string) blockfmt.RowFormat {
			return blockfmt.UnsafeION()
		},
		Logf: t.Logf,
		// force re-scanning; we will only be
		// able to ingest two objects at once
		MaxScanBytes: 2 * 1024 * 1024,

		NewIndexScan: true,
	}

	lst, err := collectGlob(dfs, b.Fallback, "b-prefix/*.block")
	if err != nil {
		t.Fatal(err)
	}

	err = b.append(owner, "default", "taxi", lst, nil)
	if err != ErrBuildAgain {
		t.Fatal("got err", err)
	}

	idx, err := OpenIndex(dfs, "default", "taxi", owner.Key())
	if err != nil {
		t.Fatal(err)
	}
	if !idx.Scanning {
		t.Error("index is not scanning?")
	}
	if idx.Objects() != 1 {
		t.Errorf("idx.Objects() = %d", idx.Objects())
	}

	// second attempt should fail again,
	// but Scanning should be false
	err = b.append(owner, "default", "taxi", lst, nil)
	if err != ErrBuildAgain {
		t.Fatal("got err", err)
	}
	idx, err = OpenIndex(dfs, "default", "taxi", owner.Key())
	if err != nil {
		t.Fatal(err)
	}
	if idx.Scanning {
		t.Error("expected !Scanning")
	}

	idx.Inputs.Backing = dfs
	count := 0
	err = idx.Inputs.Walk("", func(name, etag string, id int) bool {
		if name != fmt.Sprintf("file://b-prefix/nyc-taxi%d.block", count) {
			t.Errorf("name = %s ?", name)
		}
		if id != 0 {
			t.Errorf("id(%s) = %d?", name, id)
		}
		count++
		return true
	})
	if err != nil {
		t.Fatal(err)
	}
	if count != objects {
		t.Fatalf("expected %d objects in input; got %d", objects, count)
	}

	// final append should be a no-op
	err = b.append(owner, "default", "taxi", lst, nil)
	if err != nil {
		t.Fatal(err)
	}
	noScan(t, &b, owner, "default", "taxi")
}

func TestScanFail(t *testing.T) {
	checkFiles(t)
	tmpdir := t.TempDir()
	for _, dir := range []string{
		filepath.Join(tmpdir, "b-prefix"),
	} {
		err := os.MkdirAll(dir, 0750)
		if err != nil {
			t.Fatal(err)
		}
	}

	dfs := newDirFS(t, tmpdir)
	err := WriteDefinition(dfs, "default", &Definition{
		Name: "files",
		Inputs: []Input{
			{Pattern: "file://b-prefix/*.json"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	const (
		good0 = 3
		bad   = 2
		good1 = 3
		total = good0 + bad + good1
	)

	for i := 0; i < good0; i++ {
		name := fmt.Sprintf("b-prefix/file%d.json", i)
		value := fmt.Sprintf(`{"good": true, "filenum": %d}`, i)
		_, err := dfs.WriteFile(name, []byte(value))
		if err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < bad; i++ {
		name := fmt.Sprintf("b-prefix/file%d.json", good0+i)
		value := fmt.Sprintf(`{"good": false, filenum%d`, i)
		_, err := dfs.WriteFile(name, []byte(value))
		if err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < good1; i++ {
		name := fmt.Sprintf("b-prefix/file%d.json", good0+bad+i)
		value := fmt.Sprintf(`{"good": true, "filenum": %d}`, good0+bad+i)
		_, err := dfs.WriteFile(name, []byte(value))
		if err != nil {
			t.Fatal(err)
		}
	}

	owner := newTenant(dfs)
	b := Builder{
		Align:          1024,
		Logf:           t.Logf,
		MaxScanObjects: 2,
		NewIndexScan:   true,
	}

	fullScan(t, &b, owner, "default", "files", good0+good1)
	noScan(t, &b, owner, "default", "files")
}
