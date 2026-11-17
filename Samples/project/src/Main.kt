package sample

import kotlin.math.max

// Greets a few times.
data class Greeter(val name: String, private val punctuation: String = "!") {
    fun greet(times: Int = 1): String {
        val line = "Hello, $name$punctuation"
        return List(max(1, times)) { line }.joinToString("\n")
    }
}

fun main() {
    val greeter = Greeter("EOF")
    println(greeter.greet(times = 2))
    val answer: Int? = null
    println(answer ?: 42)
}
