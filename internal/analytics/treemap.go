package analytics

import "math"

// Rect is a rectangle in points (origin top-left or bottom-left, whichever the caller uses).
type Rect struct {
	X, Y, W, H float64
}

// Treemap is a squarified treemap: it splits rect into tiles whose areas are proportional to the values and as
// close to squares as the order allows. One rectangle per value, in the same order; pass the values biggest
// first. Values of zero or less get an empty rectangle.
func Treemap(values []float64, rect Rect) []Rect {
	out := make([]Rect, len(values))
	total := 0.0
	for _, v := range values {
		total += max(0, v)
	}
	if total <= 0 || rect.W <= 0 || rect.H <= 0 {
		return out
	}
	scale := rect.W * rect.H / total
	areas := make([]float64, len(values))
	for i, v := range values {
		areas[i] = max(0, v) * scale
	}
	free := rect
	for i := 0; i < len(areas); {
		side := min(free.W, free.H)
		if side <= 0 {
			break
		}
		// Grow the row for as long as its worst tile gets closer to a square
		row := []float64{areas[i]}
		sum := areas[i]
		j := i + 1
		for j < len(areas) && worst(append(row[:len(row):len(row)], areas[j]), sum+areas[j], side) <= worst(row, sum, side) {
			row = append(row, areas[j])
			sum += areas[j]
			j++
		}
		// The row runs along the shorter side and takes a strip off the free rectangle
		thickness := sum / side
		alongHeight := free.W >= free.H
		offset := 0.0
		for k, area := range row {
			length := 0.0
			if thickness > 0 {
				length = area / thickness
			}
			if alongHeight {
				out[i+k] = Rect{X: free.X, Y: free.Y + offset, W: thickness, H: length}
			} else {
				out[i+k] = Rect{X: free.X + offset, Y: free.Y, W: length, H: thickness}
			}
			offset += length
		}
		if alongHeight {
			free = Rect{X: free.X + thickness, Y: free.Y, W: max(0, free.W-thickness), H: free.H}
		} else {
			free = Rect{X: free.X, Y: free.Y + thickness, W: free.W, H: max(0, free.H-thickness)}
		}
		i = j
	}
	return out
}

// worst is the worst aspect ratio in a row of areas laid along a side.
func worst(row []float64, sum, side float64) float64 {
	if len(row) == 0 {
		return math.Inf(1)
	}
	largest, smallest := row[0], row[0]
	for _, a := range row[1:] {
		largest = max(largest, a)
		smallest = min(smallest, a)
	}
	if smallest <= 0 || sum <= 0 {
		return math.Inf(1)
	}
	side2, sum2 := side*side, sum*sum
	return max(side2*largest/sum2, sum2/(side2*smallest))
}
