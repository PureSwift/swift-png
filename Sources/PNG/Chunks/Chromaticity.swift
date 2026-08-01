// Chromaticity.swift - the same colours said two ways
//
// A file records what its red, green and blue actually are as chromaticities: a pair of numbers per
// primary saying where it sits on the diagram of visible colour, plus the white the three of them add
// up to.  A client working in colour usually wants the other form — the matrix that takes the file's
// three channels to the space every colour space is defined against.
//
// The two hold the same information and the conversion is exact in both directions, which is worth
// saying because the numbers do not look like it: the matrix has nine entries and the chromaticities
// eight, and the ninth is not free — it is what makes the three primaries add up to the white point.

extension Chromaticity {
    /// The matrix form: what each primary contributes, in the space colour is measured in.
    ///
    /// Absent when the numbers cannot describe a colour space at all — three primaries that lie on a
    /// line have no area between them, and a white point outside them is a white no mixture of them
    /// could make.  A file can say either, so both are answered with nothing rather than a matrix.
    public var asXYZ: (
        red: (x: Double, y: Double, z: Double),
        green: (x: Double, y: Double, z: Double),
        blue: (x: Double, y: Double, z: Double)
    )? {
        let scale = 1e-5

        let rx = Double(self.redX) * scale, ry = Double(self.redY) * scale
        let gx = Double(self.greenX) * scale, gy = Double(self.greenY) * scale
        let bx = Double(self.blueX) * scale, by = Double(self.blueY) * scale
        let wx = Double(self.whiteX) * scale, wy = Double(self.whiteY) * scale

        guard ry > 0, gy > 0, by > 0, wy > 0 else { return nil }

        // How much of each primary the white is made of.  That is the whole of the conversion: once
        // the three weights are known, each column of the matrix is its primary scaled by its weight.
        //
        // The white is written with its middle number as one, which is the convention every colour
        // space is quoted in — a colour space says what its colours *are*, not how bright the display
        // showing them happens to be.
        let white = (x: wx / wy, y: 1.0, z: (1 - wx - wy) / wy)

        let red = (x: rx, y: ry, z: 1 - rx - ry)
        let green = (x: gx, y: gy, z: 1 - gx - gy)
        let blue = (x: bx, y: by, z: 1 - bx - by)

        // Three equations, three unknowns, solved by the ratio of determinants.  Written out rather
        // than reduced, because the reduced form is where the sign errors live.
        func determinant(
            _ a: (x: Double, y: Double, z: Double),
            _ b: (x: Double, y: Double, z: Double),
            _ c: (x: Double, y: Double, z: Double)
        ) -> Double {
            a.x * (b.y * c.z - b.z * c.y)
                - b.x * (a.y * c.z - a.z * c.y)
                + c.x * (a.y * b.z - a.z * b.y)
        }

        let whole = determinant(red, green, blue)

        guard whole != 0 else { return nil }

        let redWeight = determinant(white, green, blue) / whole
        let greenWeight = determinant(red, white, blue) / whole
        let blueWeight = determinant(red, green, white) / whole

        // A colour space whose white is outside the triangle its primaries make is not one: no
        // mixture of them could produce it, and the negative weight is what says so.
        guard redWeight > 0, greenWeight > 0, blueWeight > 0 else { return nil }

        func column(
            _ primary: (x: Double, y: Double, z: Double),
            _ weight: Double
        ) -> (x: Double, y: Double, z: Double) {
            (x: weight * primary.x, y: weight * primary.y, z: weight * primary.z)
        }

        return (
            red: column(red, redWeight),
            green: column(green, greenWeight),
            blue: column(blue, blueWeight)
        )
    }

    /// The reverse: chromaticities from a matrix.
    ///
    /// Each primary's pair is its own contribution divided by the total, and the white point is what
    /// the three of them add up to — which is why the ninth number was never free.
    public static func from(
        red: (x: Double, y: Double, z: Double),
        green: (x: Double, y: Double, z: Double),
        blue: (x: Double, y: Double, z: Double)
    ) -> Chromaticity? {
        func pair(_ column: (x: Double, y: Double, z: Double)) -> (Double, Double)? {
            let total = column.x + column.y + column.z

            guard total > 0 else { return nil }

            return (column.x / total, column.y / total)
        }

        guard let redPair = pair(red), let greenPair = pair(green), let bluePair = pair(blue),
              let whitePair = pair((
                  x: red.x + green.x + blue.x,
                  y: red.y + green.y + blue.y,
                  z: red.z + green.z + blue.z
              )) else {
            return nil
        }

        var result = Chromaticity()

        func fixed(_ value: Double) -> FixedPoint {
            FixedPoint((value * 100_000).rounded())
        }

        result.whiteX = fixed(whitePair.0)
        result.whiteY = fixed(whitePair.1)
        result.redX = fixed(redPair.0)
        result.redY = fixed(redPair.1)
        result.greenX = fixed(greenPair.0)
        result.greenY = fixed(greenPair.1)
        result.blueX = fixed(bluePair.0)
        result.blueY = fixed(bluePair.1)

        return result
    }
}
