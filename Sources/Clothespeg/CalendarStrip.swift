import AppKit
import SwiftUI

/// One day in the row of days along the pill.
///
/// A button, the same as the two named days beside it and for the same reason.
/// It used to be a drag: press a day and drag across the ones after it to take
/// the whole stretch. That made the row two controls wearing one row's
/// clothes — today and yesterday by click, everything else by drag — so the
/// familiar half worked and the rest did not, and the days that needed a drag
/// read as broken buttons. A row where some cells answer a click and the rest
/// need a gesture is a row that has to be learned.
///
/// One day at a time, and pressing the day that is already chosen takes it
/// away. That is the same thing the filter's segments do, the same thing the
/// two named days do, and the same thing every other control on the pill does
/// — so there is nothing here that has to be remembered.
struct DayChip: View {
    let offset: Int
    /// Whether this day is the one in force.
    let isLit: Bool
    var onPick: () -> Void

    /// How many days the row holds, today included.
    static let days = 14
    /// The width of one day. Enough for "9/30" and for a number with room to
    /// breathe either side of it.
    static let cellWidth: CGFloat = 28

    /// Today and yesterday are named rather than numbered: they are the two
    /// days anyone looks for by name. The rest is a bare number, and the ones
    /// in another month carry that month with them.
    ///
    /// No weekday. It was there to be an anchor — the eye finds "Friday"
    /// before it reads a number — but these days are consecutive, so a weekday
    /// says which week a day is in when the only question is which day it is.
    ///
    /// The month is a different matter, and it is written as a prefix rather
    /// than as a separate word: fourteen days back from the eleventh of a
    /// month crosses into the one before it, and a bare "30" following a run
    /// of numbers up to "1" is not that day. `9/30` says it in five characters
    /// where "9月30日" says it in four that do not fit a twenty-eight point
    /// cell.
    private var label: String {
        let calendar = Calendar.current
        let day = Self.day(offset)
        let dayOfMonth = calendar.component(.day, from: day)
        guard calendar.component(.month, from: day)
                != calendar.component(.month, from: Date()) else {
            return "\(dayOfMonth)"
        }
        return "\(calendar.component(.month, from: day))/\(dayOfMonth)"
    }

    var body: some View {
        Button(action: onPick) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                // The word lit and nothing behind it, which is how the
                // filter's chosen word says so. A filled block on the day as
                // well would be saying it twice, and from across the screen a
                // lit word next to a filled block reads as one thing rather
                // than as a set.
                .foregroundStyle(isLit ? Color.accentColor : Color.secondary)
                .frame(width: Self.cellWidth, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The day `offset` days **back** from today, at the start of it.
    ///
    /// Negative, and that is the whole of it: a row that counts forwards is a
    /// row of days that have not happened yet, and the first version of this
    /// did exactly that — it read "13 14 15" beside a today of the eleventh
    /// and meant the thirteenth, the fourteenth and the fifteenth to come.
    static func day(_ offset: Int) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }
}

/// The dates, on the pill itself.
///
/// Three states, and each one is smaller than the one before it.
///
/// Shut: one clock. Dates are the filter that gets used least — a clipboard is
/// looked at because of something recent, and the search box finds anything
/// from anywhere in the history — so the thing that is seldom wanted is the
/// thing that takes the least room when it is not wanted.
///
/// Open: today and yesterday, and a way past them. Two days anyone looks for
/// by name, each one click rather than a click to open a row and then another
/// click to find the right cell in it.
///
/// Open further: the rest of the days, along the pill rather than beside it.
/// A row of days in its own window is nearly twice the pill's height, and a
/// control twice the height of the thing it belongs to reads as a different
/// thing entirely — it looked like a menu from another app. Along the pill it
/// is the same height, the same glass and the same row.
///
/// All of it in the pill rather than over it, which is the whole reason for
/// the folding. A second window means a second thing to be in the way, and the
/// pill is a strip over the top of the screen: anything beside it covers
/// something.
struct DateButton: View {
    @ObservedObject var line: Line
    /// 0 is the clock alone, 1 adds the two named days, 2 adds the row.
    @Binding var level: Int

    var body: some View {
        HStack(spacing: 3) {
            if level == 0 {
                clock
            } else {
                namedDays
                if level == 2 {
                    theRow
                } else {
                    wayOn
                }
                // Always here once the dates are open, and not only once one
                // is chosen. It was the way out of a choice, which left the
                // open row with no way out of itself: with nothing chosen
                // there was no cross, and the only way to put the row away was
                // to choose a day and then press the cross that choosing it
                // had just produced. A way out that exists only after you have
                // gone in is not a way out.
                //
                // Its meaning is the same either way — clear, and leave — and
                // clearing nothing is leaving.
                closeButton
            }
        }
        // The pill's icon-button shape: content, four points of air on each
        // side, eighteen points tall — open row or clock alone, the outer
        // edge sits at the same distance from the divider beside it either
        // way. The trailing and horizontal paddings this replaced leant on
        // the button's state, which is why the dates sat closer to one
        // neighbour than to the other.
        .frame(minHeight: 18)
        .padding(.horizontal, 4)
        .animation(.easeOut(duration: 0.14), value: level)
        .animation(.easeOut(duration: 0.12), value: line.dateRange)
    }

    /// Clear what is set and fold the row away.
    private var closeButton: some View {
        Button {
            line.dateRange = nil
            fold()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 2)
    }

    // MARK: Shut

    private var clock: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) { level = 1 }
        } label: {
            // The range, when one is set and the days are not on screen, is
            // beside the clock rather than laid over it. An overlay does not
            // take part in the parent's sizing, so the pill — which is the
            // clock's own background — was drawn eighteen points wide with the
            // date sitting outside it, on the panel and not on the pill.
            //
            // A lit clock says something is set and not what, and with the row
            // folded away this is the only place left to say what.
            HStack(spacing: 2) {
                Image(systemName: line.dateRange == nil ? "clock" : "calendar")
                    .font(.system(size: 9, weight: .semibold))
                if let range = line.dateRange {
                    Text(range.label)
                        .font(.system(size: 10, weight: .medium))
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .foregroundStyle(line.dateRange == nil ? Color.secondary : Color.accentColor)
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Open

    private var namedDays: some View {
        Group {
            segment(L("Today"), selected: isToday) {
                pick(Calendar.current.startOfDay(for: Date()))
                fold()
            }
            segment(L("Yesterday"), selected: isYesterday) {
                let day = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                pick(day)
                fold()
            }
        }
    }

    private var wayOn: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) { level = 2 }
        } label: {
            // Three dots rather than a chevron: the row opens beside them
            // rather than below, and a chevron is the mark for something
            // opening downwards.
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The days, each one a button.
    ///
    /// Built as an array rather than written as a range. The range this used
    /// to be was `-2..<(-13)`, and a range whose lower bound is above its
    /// upper bound is not an empty range — it is a crash: `Fatal error: Range
    /// requires lowerBound <= upperBound`, thrown the moment the row was first
    /// drawn, which is the moment the three dots were pressed. The whole app
    /// went with it, and it read as the line closing.
    ///
    /// `Self.offsets` cannot have that shape. It counts upwards and negates, so
    /// there is no ordering to get wrong.
    private var theRow: some View {
        HStack(spacing: 3) {
            ForEach(Self.offsets, id: \.self) { offset in
                DayChip(offset: offset, isLit: isLit(offset)) {
                    pick(DayChip.day(offset))
                }
            }
            // The rest of the window, as one word. The row draws fourteen
            // days and the setting can keep ninety; drawing ninety cells
            // would be a strip twice the screen rather than a filter, and
            // the truth is that a day this old is looked for as a stretch
            // and not as a date — so one button stands for all of it, and
            // what it filters is the whole of the window past the row.
            // Absent when the window is the row: fourteen days has no
            // earlier to reach.
            if let earlier = earlierRange {
                Button {
                    line.dateRange = line.dateRange == earlier ? nil : earlier
                } label: {
                    Text(L("Earlier"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(line.dateRange == earlier ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Everything the row does not reach, out to the retention window's
    /// edge. From the oldest day kept to the first day past the row — a
    /// stretch, which is how a day this old is asked for.
    private var earlierRange: DateRange? {
        guard Attic.retentionDays > DayChip.days else { return nil }
        return DateRange(from: DayChip.day(-(Attic.retentionDays - 1)),
                         until: DayChip.day(-DayChip.days))
    }

    /// The days the row holds, from the day before yesterday backwards.
    ///
    /// Counted upwards and negated, so the order is the order of the counting
    /// and cannot be a pair of bounds the wrong way round. A range written as
    /// `-2..<(-13)` is not empty, it is a fatal error — and it is drawn on the
    /// first press of the three dots, so the whole app goes with it.
    ///
    /// Today and yesterday are not here: they are named and live beside this
    /// row already, which is what makes the row read as one row that happens
    /// to be folded rather than two rows.
    static var offsets: [Int] {
        (2...(DayChip.days - 1)).map { -$0 }
    }

    // MARK: Choosing

    /// One day, or none.
    ///
    /// Pressing the day already chosen takes the date away, so the control is
    /// its own undo — which is what every other control on the pill does, and
    /// what makes a second press mean "never mind" rather than nothing.
    private func pick(_ day: Date) {
        let calendar = Calendar.current
        if let range = line.dateRange, range.isSingleDay,
           calendar.isDate(range.from, inSameDayAs: day) {
            line.dateRange = nil
        } else {
            line.dateRange = DateRange(from: day, until: day)
        }
    }

    /// Whether the day in force is this one.
    private func isLit(_ offset: Int) -> Bool {
        guard let range = line.dateRange, range.isSingleDay else { return false }
        return Calendar.current.isDate(range.from, inSameDayAs: DayChip.day(offset))
    }

    /// Back to the clock, from anywhere deeper.
    ///
    /// Folded rather than dropped, because a row of days left open across a
    /// hide and a return would be a wide strip of numbers waiting on top of a
    /// card every time the line came down.
    private func fold() {
        withAnimation(.easeOut(duration: 0.14)) { level = 0 }
    }

    /// One named day, lit when the day in force is that one.
    ///
    /// Lit the way the days in the row are — the word changes colour and
    /// nothing behind it does. A filled capsule here and a filled capsule in
    /// the row would be the same answer twice over.
    private func segment(_ title: String, selected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isToday: Bool {
        guard let range = line.dateRange else { return false }
        return range.isSingleDay && Calendar.current.isDateInToday(range.from)
    }

    private var isYesterday: Bool {
        guard let range = line.dateRange, range.isSingleDay else { return false }
        return Calendar.current.isDateInYesterday(range.from)
    }
}
