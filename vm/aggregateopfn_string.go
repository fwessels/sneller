// Code generated by "stringer -type=AggregateOpFn"; DO NOT EDIT.

package vm

import "strconv"

func _() {
	// An "invalid array index" compiler error signifies that the constant values have changed.
	// Re-run the stringer command to generate them again.
	var x [1]struct{}
	_ = x[AggregateOpNone-0]
	_ = x[AggregateOpSumF-1]
	_ = x[AggregateOpAvgF-2]
	_ = x[AggregateOpMinF-3]
	_ = x[AggregateOpMaxF-4]
	_ = x[AggregateOpSumI-5]
	_ = x[AggregateOpSumC-6]
	_ = x[AggregateOpAvgI-7]
	_ = x[AggregateOpMinI-8]
	_ = x[AggregateOpMaxI-9]
	_ = x[AggregateOpAndI-10]
	_ = x[AggregateOpOrI-11]
	_ = x[AggregateOpXorI-12]
	_ = x[AggregateOpAndK-13]
	_ = x[AggregateOpOrK-14]
	_ = x[AggregateOpMinTS-15]
	_ = x[AggregateOpMaxTS-16]
	_ = x[AggregateOpCount-17]
	_ = x[AggregateOpApproxCountDistinct-18]
	_ = x[AggregateOpApproxCountDistinctPartial-19]
	_ = x[AggregateOpApproxCountDistinctMerge-20]
}

const _AggregateOpFn_name = "AggregateOpNoneAggregateOpSumFAggregateOpAvgFAggregateOpMinFAggregateOpMaxFAggregateOpSumIAggregateOpSumCAggregateOpAvgIAggregateOpMinIAggregateOpMaxIAggregateOpAndIAggregateOpOrIAggregateOpXorIAggregateOpAndKAggregateOpOrKAggregateOpMinTSAggregateOpMaxTSAggregateOpCountAggregateOpApproxCountDistinctAggregateOpApproxCountDistinctPartialAggregateOpApproxCountDistinctMerge"

var _AggregateOpFn_index = [...]uint16{0, 15, 30, 45, 60, 75, 90, 105, 120, 135, 150, 165, 179, 194, 209, 223, 239, 255, 271, 301, 338, 373}

func (i AggregateOpFn) String() string {
	if i >= AggregateOpFn(len(_AggregateOpFn_index)-1) {
		return "AggregateOpFn(" + strconv.FormatInt(int64(i), 10) + ")"
	}
	return _AggregateOpFn_name[_AggregateOpFn_index[i]:_AggregateOpFn_index[i+1]]
}
