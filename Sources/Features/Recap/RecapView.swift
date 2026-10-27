import Charts
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Listening recap for a week, month or year: time listened, top artists and songs, hours of
/// the day and new artists, from the plays recorded on the device.
struct RecapView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var period: RecapPeriod = .month
    /// 0 = the current period, -1 the one before, …
    @State private var offset = 0

    private var interval: RecapInterval {
        RecapInterval(period: self.period, containing: .now).shifted(by: self.offset)
    }

    var body: some View {
        let plays = self.environment.listening.plays
        let recap = Recap(plays: plays, interval: self.interval)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Picker("Period", selection: self.$period) {
                    ForEach(RecapPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: self.period) { _, _ in self.offset = 0 }

                self.periodHeader(recap, canGoBack: plays.first.map { $0.startedAt < recap.interval.start } ?? false)

                if recap.plays == 0 {
                    ContentUnavailableView {
                        Label("Nothing played", systemImage: "chart.bar")
                    } description: {
                        if plays.isEmpty {
                            Text("Plays are recorded on this iPhone from now on, once a song has played for 30 seconds.")
                        } else {
                            Text("No songs were played in this period.")
                        }
                    }
                } else {
                    self.summary(recap)
                    self.artists(recap)
                    self.tracks(recap)
                    self.hours(recap)
                    self.newArtists(recap)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Sections

    private func periodHeader(_ recap: Recap, canGoBack: Bool) -> some View {
        HStack {
            Button("Previous", systemImage: "chevron.left") { self.offset -= 1 }
                .labelStyle(.iconOnly)
                .disabled(!canGoBack)
            Spacer()
            Text(recap.interval.title()).font(.headline)
            Spacer()
            if recap.plays > 0 {
                ShareLink(
                    item: RecapCardImage(recap: recap),
                    preview: SharePreview(Text("My listening recap"), image: Image(systemName: "chart.bar"))
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            Button("Next", systemImage: "chevron.right") { self.offset += 1 }
                .labelStyle(.iconOnly)
                .disabled(self.offset >= 0)
        }
        .font(.title3)
    }

    private func summary(_ recap: Recap) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(recap.minutes) min")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(Color.brand)
            Text("\(recap.plays) plays · \(recap.artistCount) artists")
                .foregroundStyle(.secondary)
            if let change = recap.change {
                HStack(spacing: 4) {
                    Label(
                        change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())),
                        systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                    .fontWeight(.semibold)
                    .foregroundStyle(change >= 0 ? .green : .orange)
                    Text("vs. the period before").foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }

    private func artists(_ recap: Recap) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top artists").font(.title2.bold())
            ForEach(Array(recap.topArtists.enumerated()), id: \.element.id) { index, artist in
                HStack(spacing: 12) {
                    Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                    ArtworkView(url: artist.artworkURL)
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).font(.body.weight(.medium)).lineLimit(1)
                        Text("\(artist.minutes) min · \(artist.plays) plays").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func tracks(_ recap: Recap) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top songs").font(.title2.bold())
            ForEach(Array(recap.topTracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    self.environment.player.startRadio(videoId: track.videoId)
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        ArtworkView(url: track.artworkURL)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.body.weight(.medium)).lineLimit(1)
                            Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text("\(track.plays)×").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func hours(_ recap: Recap) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hours of the day").font(.title2.bold())
            if let peak = recap.peakHour {
                Text("Mostly around \(Self.hourLabel(peak))").foregroundStyle(.secondary)
            }
            Chart(Array(recap.minutesByHour.enumerated()), id: \.offset) { hour, minutes in
                BarMark(x: .value("Hour", hour), y: .value("Minutes", minutes))
                    .foregroundStyle(Color.brand.gradient)
            }
            .chartXScale(domain: 0 ... 23)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Self.hourLabel(value.as(Int.self) ?? 0)) }
                }
            }
            .frame(height: 160)
        }
    }

    @ViewBuilder
    private func newArtists(_ recap: Recap) -> some View {
        if let artists = recap.newArtists, !artists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("New artists").font(.title2.bold())
                Text("\(artists.count) artists played for the first time").foregroundStyle(.secondary)
                Text(artists.prefix(12).joined(separator: " · "))
                    .font(.subheadline)
            }
        }
    }

    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }
}

// MARK: - Shareable card

/// The recap drawn as a picture for the share sheet (rendered only when shared).
struct RecapCardImage: Transferable {
    let recap: Recap

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try await MainActor.run {
                let renderer = ImageRenderer(content: RecapCard(recap: item.recap))
                renderer.scale = 3
                guard let data = renderer.uiImage?.pngData() else { throw CocoaError(.fileWriteUnknown) }
                return data
            }
        }
    }
}

/// Text only: artwork is loaded asynchronously and would not be in the rendered picture.
struct RecapCard: View {
    let recap: Recap

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("My listening recap").font(.headline).opacity(0.8)
                Text(self.recap.interval.title()).font(.title.bold())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(self.recap.minutes)")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                Text("minutes · \(self.recap.plays) plays").font(.headline).opacity(0.8)
            }
            self.list(title: "Top artists", rows: self.recap.topArtists.prefix(5).map(\.name))
            self.list(title: "Top songs", rows: self.recap.topTracks.prefix(5).map { "\($0.title) — \($0.artist)" })
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Text(verbatim: "Kaset").font(.footnote.weight(.semibold)).opacity(0.7)
            }
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(width: 360, height: 640, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Color.brand, Color(red: 0.25, green: 0.05, blue: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func list(title: LocalizedStringKey, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.bold)).textCase(.uppercase).opacity(0.75)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Text(verbatim: "\(index + 1). \(row)").font(.body.weight(.medium)).lineLimit(1)
            }
        }
    }
}
