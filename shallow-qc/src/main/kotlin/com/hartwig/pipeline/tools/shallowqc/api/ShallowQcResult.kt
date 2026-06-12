package com.hartwig.pipeline.tools.shallowqc.api

data class ShallowQcResult(
    val tumorSampleName: String,
    val referenceSampleName: String,
    val purpleStatus: List<String>,
    val purpleFitMethod: String,
    val amberStatus: String,
    val tumorCellPurity: Double,
    val shallowSequencingStatus: String
)