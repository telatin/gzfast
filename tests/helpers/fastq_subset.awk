# Preserve complete records, including wrapped sequence and quality lines.
function fail(message) {
    print "FASTQ error at line " NR ": " message > "/dev/stderr"
    failed = 1
    exit 1
}
{
    line = $0
    sub(/\r$/, "", line)
    if (state == 0) {
        if (substr(line, 1, 1) != "@") fail("expected a read header")
        record = $0 ORS
        sequenceLength = qualityLength = 0
        state = 1
    } else if (state == 1) {
        record = record $0 ORS
        if (substr(line, 1, 1) == "+") state = 2
        else sequenceLength += length(line)
    } else {
        record = record $0 ORS
        qualityLength += length(line)
        if (qualityLength > sequenceLength) fail("quality exceeds sequence length")
        if (qualityLength == sequenceLength) {
            records++
            bytes += length(record)
            if (!statsOnly && (!maxRecords || selectedRecords < maxRecords) &&
                (!maxBytes || selectedBytes < maxBytes)) {
                printf "%s", record
                selectedRecords++
                selectedBytes += length(record)
            }
            state = 0
        }
    }
}
END {
    if (failed) exit 1
    if (state != 0) fail("incomplete record")
    if (records == 0) fail("no records found")
    if (statsOnly) printf "%.0f %.0f\n", records, bytes
    if (reportFile != "") printf "%.0f %.0f\n", selectedRecords, selectedBytes > reportFile
}
