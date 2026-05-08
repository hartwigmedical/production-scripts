package com.hartwig.pipeline.tools.shallowqc.api

import tools.jackson.databind.DeserializationFeature
import tools.jackson.databind.json.JsonMapper
import tools.jackson.module.kotlin.kotlinModule
import tools.jackson.module.kotlin.readValue
import com.hartwig.pipeline.tools.shallowqc.model.PipelineMetadata
import com.hartwig.pipeline.tools.shallowqc.model.PurpleResult
import io.github.oshai.kotlinlogging.KotlinLogging
import picocli.CommandLine.Command
import picocli.CommandLine.Option
import java.io.File
import java.math.BigDecimal
import java.util.concurrent.Callable

private val logger = KotlinLogging.logger {}

@Command(
    name = "shallow-qc",
    description = ["Generate shallow QC JSON from molecular pipeline output"]
)
class ShallowQcCommand : Callable<Int> {

    @Option(names = ["--pipeline-output-dir"], required = true, description = ["Path to the pipeline output directory"])
    private lateinit var pipelineOutputDir: File

    @Option(names = ["--output-dir"], description = ["Directory to write output to (default: current directory)"])
    private var outputDir: File = File(".")

    private val mapper = JsonMapper.builder()
        .addModule(kotlinModule())
        .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
        .build()

    override fun call(): Int {
        try {
            val pipelineMetadata = mapper.readValue<PipelineMetadata>(pipelineOutputDir.resolve("metadata.json"))
            val tumorSampleName = pipelineMetadata.tumor.sampleName
            val referenceSampleName = pipelineMetadata.reference.sampleName

            val amberStatus = readQcStatus(pipelineOutputDir.resolve("amber/${tumorSampleName}.amber.qc"))
            val purpleQcStatus = readQcStatus(pipelineOutputDir.resolve("purple/${tumorSampleName}.purple.qc"))
            val purpleResult = readPurpleResult(pipelineOutputDir, tumorSampleName)
            val tumorCoverage = readMeanCoverage(pipelineOutputDir, tumorSampleName)
            val referenceCoverage = readMeanCoverage(pipelineOutputDir, referenceSampleName)

            val shallowSequencingStatus = computeShallowSequencingStatus(
                amberStatus, purpleQcStatus, purpleResult.purity, tumorCoverage, referenceCoverage
            )

            val result = ShallowQcResult(
                tumorIsolationBarcode = pipelineMetadata.tumor.barcode,
                referenceIsolationBarcode = pipelineMetadata.reference.barcode,
                purpleStatus = purpleQcStatus.split(","),
                purpleFitMethod = purpleResult.fitMethod,
                amberStatus = amberStatus,
                tumorCellPurity = purpleResult.purity.toDouble() * 100.0,
                shallowSequencingStatus = shallowSequencingStatus
            )

            val resultFile = outputDir.resolve("shallow-qc.json")
            mapper.writerWithDefaultPrettyPrinter().writeValue(resultFile, result)
            return 0
        } catch (e: Exception) {
            logger.error(e) { "Failed to run shallow QC" }
            return 1
        }
    }
}

internal fun readQcStatus(file: File): String {
    logger.info { "Reading QC status from ${file.path}" }
    val status = file.readLines().first { it.startsWith("QCStatus") }.split("\t")[1].trim()
    logger.info { "QC status from [${file.path}]: [$status]" }
    return status
}

internal fun readPurpleResult(pipelineOutputDir: File, tumSampleName: String): PurpleResult {
    val file = pipelineOutputDir.resolve("purple/${tumSampleName}.purple.purity.tsv")
    logger.info { "Reading purple purity from [${file.path}]" }
    val lines = file.readLines()

    val headers = lines[0].split("\t")
    val values = lines[1].split("\t")

    val purplePurity = PurpleResult(BigDecimal(values[headers.indexOf("purity")]), values[headers.indexOf("status")])
    logger.info { "Purple purity: purity=[${purplePurity.purity}], fitMethod=[${purplePurity.fitMethod}]" }

    return purplePurity
}

internal fun readMeanCoverage(pipelineOutputDir: File, sampleName: String): Double {
    val file = pipelineOutputDir.resolve("${sampleName}/bam_metrics/${sampleName}.wgsmetrics")
    logger.info { "Reading mean coverage from [${file.path}]" }
    val lines = file.readLines()

    val headerIndex = lines.indexOfFirst { it.startsWith("GENOME_TERRITORY") }
    require(headerIndex >= 0) { "GENOME_TERRITORY header not found in [${file.path}]" }

    val headers = lines[headerIndex].split("\t")
    val values = lines[headerIndex + 1].split("\t")

    val coverage = values[headers.indexOf("MEAN_COVERAGE")].toDouble()
    logger.info { "Mean coverage for [$sampleName]: [$coverage]" }

    return coverage
}
