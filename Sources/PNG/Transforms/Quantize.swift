// Quantize.swift - fitting an image into fewer colours than it has
//
// For a display that cannot show every colour in the file.  The client says how many it can show and
// hands over a palette; what comes back is a palette no longer than that and rows of indices into it.
//
// Two quite different jobs hide behind the one request, and which one runs depends on what the client
// passes.  If the palette is longer than the display can take, it has to be shortened — and that is a
// choice about which colours to lose, made either from a histogram the file supplied or, when there is
// none, by finding the two colours closest together and keeping one of them.  Separately, if the image
// is colour rather than indices, every pixel has to be found a palette entry, which is done through a
// table over the top five bits of each channel rather than by searching the palette per pixel.
//
// The colour distances here are not distances anyone would defend.  Nearness is measured by adding the
// three channel differences and then adding the largest of them again, and the search over the palette
// works by repeatedly merging the closest pair rather than by anything that minimises a total.  Both
// are the reference's, and both are reproduced rather than improved: a client that asked for this
// asked for a particular set of colours, and a better answer is still a different one.

/// The tables a request to reduce the colours leaves behind.
///
/// One or the other, never both: a client that asks for the full reduction gets the lookup, and one
/// that asks only for the palette to be shortened gets the map.  Which it asked for also settles what
/// the request can do — an image of colours can only be reduced through the lookup, and rows of
/// indices only through the map.
public struct Quantization {
    /// Index to index, for rows that are already indices.
    public var indexMap: [UInt8] = []

    /// Fifteen bits of colour to an index, for rows that are colours.
    public var lookup: [UInt8] = []

    public init() {}
}

/// How the number of colours is brought down, and how a colour then finds its entry.
public enum Quantize {
    /// How many bits of each channel the lookup is built over.
    public static let bitsPerChannel = 5

    /// How near two colours are, by the reference's reckoning.
    ///
    /// The three differences added, which is a distance anyone would recognise.
    static func distance(_ a: Rgb8, _ b: Rgb8) -> Int {
        let red = Int(a.red) - Int(b.red)
        let green = Int(a.green) - Int(b.green)
        let blue = Int(a.blue) - Int(b.blue)

        return abs(red) + abs(green) + abs(blue)
    }

    /// Shortens a palette to at most `maximum` entries, in place, and says where each entry went.
    ///
    /// The palette is the client's own array and is rewritten where it lies, because that is what the
    /// client is given back: it passed the array in, and the entries it should now use are the first
    /// `maximum` of it.  Everything past those is left holding whatever the shortening put there,
    /// which is neither meaningful nor cleared.
    ///
    /// Returns the map from old index to new when the client asked for one, and nothing when it did
    /// not — a client doing the full reduction gets the lookup instead and never sees this.
    public static func reduce(
        palette: UnsafeMutableBufferPointer<Rgb8>,
        count: Int,
        maximum: Int,
        histogram: UnsafeBufferPointer<UInt16>?,
        fullQuantize: Bool
    ) -> [UInt8]? {
        var indexMap: [UInt8]? = fullQuantize
            ? nil
            : (0 ..< count).map { UInt8($0) }

        guard count > maximum else { return indexMap }

        if let histogram {
            self.reduceByFrequency(
                palette: palette,
                count: count,
                maximum: maximum,
                histogram: histogram,
                indexMap: &indexMap
            )
        } else {
            self.reduceByDistance(
                palette: palette,
                count: count,
                maximum: maximum,
                indexMap: &indexMap
            )
        }

        return indexMap
    }

    // -- when the file said which colours matter ------------------------------

    /// Keeps the colours the image uses most, and sends the rest to whichever kept colour is nearest.
    ///
    /// The file's histogram counts how often each entry appears, so the choice of what to lose needs
    /// no searching: sort by count and drop the tail.  The sort is a bubble sort run only as many
    /// passes as there are entries to drop, which leaves the head unsorted and the tail exact — and
    /// the tail is all that is being asked about.
    private static func reduceByFrequency(
        palette: UnsafeMutableBufferPointer<Rgb8>,
        count: Int,
        maximum: Int,
        histogram: UnsafeBufferPointer<UInt16>,
        indexMap: inout [UInt8]?
    ) {
        var order = (0 ..< count).map { $0 }

        var limit = count - 1
        while limit >= maximum {
            var sorted = true

            for position in 0 ..< limit where histogram[order[position]] < histogram[order[position + 1]] {
                order.swapAt(position, position + 1)
                sorted = false
            }

            if sorted { break }
            limit -= 1
        }

        // The kept colours are those whose place in that order is inside the limit, and they may be
        // anywhere in the palette.  So each slot inside the limit that holds a colour being dropped
        // takes a kept colour from beyond it, which is found by walking inwards from the end.
        var source = count

        for slot in 0 ..< maximum where order[slot] >= maximum {
            repeat {
                source -= 1
            } while order[source] >= maximum

            if indexMap == nil {
                palette[slot] = palette[source]
            } else {
                // Swapped rather than overwritten, because the colour being displaced is still needed:
                // the entries pointing at it have to be sent somewhere sensible, and that is decided
                // below by how near it is to the colours that survived.
                let displaced = palette[source]
                palette[source] = palette[slot]
                palette[slot] = displaced

                indexMap?[source] = UInt8(slot)
                indexMap?[slot] = UInt8(source)
            }
        }

        guard indexMap != nil else { return }

        // Everything still pointing outside the limit is pointing at a colour that was dropped, and
        // is sent to whichever kept colour is nearest it.
        for index in 0 ..< count where Int(indexMap![index]) >= maximum {
            let dropped = palette[Int(indexMap![index])]

            var nearest = 0
            var least = self.distance(dropped, palette[0])

            for candidate in 1 ..< maximum {
                let measured = self.distance(dropped, palette[candidate])

                if measured < least {
                    least = measured
                    nearest = candidate
                }
            }

            indexMap![index] = UInt8(nearest)
        }
    }

    // -- when it said nothing -------------------------------------------------

    /// Merges the two nearest colours until few enough are left.
    ///
    /// Nearest first, in sweeps: each sweep gathers every pair within a distance of the sweep's own
    /// limit, sorted into buckets by distance, and works through them from the closest.  When a sweep
    /// runs out of pairs and there are still too many colours, the limit widens and the next sweep
    /// gathers again from the colours that remain.
    ///
    /// Merging is not averaging.  One of the pair is simply dropped and everything that pointed at it
    /// is sent to the other, so the colours that survive are all colours the file actually named.
    /// Which of the two goes alternates with the number left, which is arbitrary and is the
    /// reference's.
    ///
    /// The bookkeeping is the awkward part.  Dropping an entry leaves a hole, which is filled by
    /// moving the last live entry into it — so the pairs gathered at the start of a sweep name places
    /// that may since have changed hands, and two arrays track where everything went.
    private static func reduceByDistance(
        palette: UnsafeMutableBufferPointer<Rgb8>,
        count: Int,
        maximum: Int,
        indexMap: inout [UInt8]?
    ) {
        var live = count
        var limit = 96

        // A distance is at most three times 255, so a sweep whose limit passes that has gathered
        // every pair there is and the next one could gather nothing new.
        while live > maximum, limit <= 765 + 96 {
            // Where each place's occupant went, and who is in each place now.  Both are read as of
            // the start of the sweep, which is when the pairs below were named.
            var whereItWent = (0 ..< count).map { $0 }
            var whoIsThere = (0 ..< count).map { $0 }

            var buckets = [[(left: Int, right: Int)]](repeating: [], count: limit + 1)

            for first in 0 ..< max(live - 1, 0) {
                for second in (first + 1) ..< live {
                    let measured = self.distance(palette[first], palette[second])

                    if measured <= limit {
                        // At the front, which is the order they come back out in: of two pairs the
                        // same distance apart, the one found later is the one merged first.
                        buckets[measured].insert((left: first, right: second), at: 0)
                    }
                }
            }

            sweep: for measured in 0 ... limit {
                for pair in buckets[measured] {
                    let leftPlace = whereItWent[pair.left]
                    let rightPlace = whereItWent[pair.right]

                    // Either may have been merged away already, in which case the pair is stale.
                    if leftPlace < live, rightPlace < live {
                        let going = live & 1 == 1 ? pair.left : pair.right
                        let staying = live & 1 == 1 ? pair.right : pair.left

                        live -= 1

                        let emptied = whereItWent[going]
                        let kept = whereItWent[staying]

                        palette[emptied] = palette[live]

                        if indexMap != nil {
                            for index in 0 ..< count {
                                if Int(indexMap![index]) == emptied {
                                    indexMap![index] = UInt8(kept)
                                }

                                // The entry that filled the hole is somewhere else now, and anything
                                // pointing at where it used to be has to follow it.
                                if Int(indexMap![index]) == live {
                                    indexMap![index] = UInt8(emptied)
                                }
                            }
                        }

                        whereItWent[whoIsThere[live]] = emptied
                        whoIsThere[emptied] = whoIsThere[live]
                        whereItWent[going] = live
                        whoIsThere[live] = going
                    }

                    if live <= maximum { break sweep }
                }
            }

            limit += 96
        }
    }

    // -- finding a colour its entry -------------------------------------------

    /// Builds the table that turns a colour into a palette index.
    ///
    /// Every colour the table can distinguish is visited once per palette entry and given the nearest
    /// entry found so far, so the table is exhaustive rather than searched: thirty two thousand
    /// entries built once, against a palette scan per pixel.
    ///
    /// The nearness used here is not the one used above.  It adds the largest channel difference to
    /// the sum of all three, which weighs a colour that is badly wrong in one channel against one
    /// that is slightly wrong in each — and it is the reference's, so it is what a client's pixels
    /// were fitted with.
    public static func lookup(
        palette: UnsafeBufferPointer<Rgb8>,
        count: Int
    ) -> [UInt8] {
        let steps = 1 << self.bitsPerChannel
        let size = 1 << (self.bitsPerChannel * 3)

        var table = [UInt8](repeating: 0, count: size)
        var nearest = [UInt8](repeating: .max, count: size)

        for index in 0 ..< min(count, 256) {
            let red = Int(palette[index].red) >> (8 - self.bitsPerChannel)
            let green = Int(palette[index].green) >> (8 - self.bitsPerChannel)
            let blue = Int(palette[index].blue) >> (8 - self.bitsPerChannel)

            for candidateRed in 0 ..< steps {
                let redDistance = abs(candidateRed - red)
                let redPart = candidateRed << (self.bitsPerChannel * 2)

                for candidateGreen in 0 ..< steps {
                    let greenDistance = abs(candidateGreen - green)
                    let sofar = redDistance + greenDistance
                    let largest = max(redDistance, greenDistance)
                    let greenPart = redPart | (candidateGreen << self.bitsPerChannel)

                    for candidateBlue in 0 ..< steps {
                        let blueDistance = abs(candidateBlue - blue)
                        let place = greenPart | candidateBlue
                        let measured = max(largest, blueDistance) + sofar + blueDistance

                        if measured < Int(nearest[place]) {
                            nearest[place] = UInt8(measured)
                            table[place] = UInt8(index)
                        }
                    }
                }
            }
        }

        return table
    }

    /// Where a colour lands in the lookup.
    static func place(red: UInt8, green: UInt8, blue: UInt8) -> Int {
        let shift = 8 - self.bitsPerChannel

        return (Int(red) >> shift) << (self.bitsPerChannel * 2)
            | (Int(green) >> shift) << self.bitsPerChannel
            | (Int(blue) >> shift)
    }
}

extension Transform {
    /// Turns a row into indices, or renumbers the indices it already holds.
    ///
    /// Which of the two, and whether anything happens at all, is decided by what the row is and which
    /// table the client's request produced.  A row of colours needs the lookup and a row of indices
    /// needs the map, and a client that asked for the wrong one of the two gets a row left alone —
    /// which is the reference's behaviour and not an oversight in it: the request says what the
    /// client wants done, and what it wants done may not apply to the image it turned out to have.
    static func quantize(
        _ row: UnsafeMutableBufferPointer<UInt8>,
        _ info: inout RowInfo,
        _ tables: Quantization
    ) {
        guard info.bitDepth == 8 else { return }

        if info.colorType == .rgb || info.colorType == .rgba, !tables.lookup.isEmpty {
            let stride = info.channels

            for pixel in 0 ..< info.width {
                let place = Quantize.place(
                    red: row[pixel * stride],
                    green: row[pixel * stride + 1],
                    blue: row[pixel * stride + 2]
                )

                row[pixel] = tables.lookup[place]
            }

            info.colorType = .palette
            info.channels = 1
            info.resize()
            return
        }

        if info.colorType.isIndexed, !tables.indexMap.isEmpty {
            for pixel in 0 ..< info.width {
                let index = Int(row[pixel])

                // An index the palette never had is left as it is.  The file is broken either way and
                // nothing can be renumbered that was never numbered; what matters is that a broken
                // file cannot make this read past the end of the map.
                if index < tables.indexMap.count {
                    row[pixel] = tables.indexMap[index]
                }
            }
        }
    }
}
