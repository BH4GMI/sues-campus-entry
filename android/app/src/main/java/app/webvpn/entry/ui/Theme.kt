package app.webvpn.entry.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/**
 * 设计系统落地。
 *
 * **每一个值都来自仓库根目录的 `DESIGN.md`**，改这里就得同时改那份文件（`designmd lint` 会校验
 * 对比度与悬空引用）。界面代码只引用 `MaterialTheme.*`，不写字面量——否则设计系统就失效了。
 */

// DESIGN.md colors（那边写 6 位 hex，这里按 Android 的 ARGB 补 FF 前缀）
private val Primary = Color(0xFF2F6FB5)
private val PrimaryDeep = Color(0xFF24548A)
private val Ink = Color(0xFF1A1C1E)
private val Secondary = Color(0xFF6C7278)
private val Neutral = Color(0xFFF5F7FA)
private val SurfaceLight = Color(0xFFFFFFFF)
private val Line = Color(0xFFE3E3E3)
private val Success = Color(0xFF2E7D5B)
private val Warning = Color(0xFF8F5500)
private val Error = Color(0xFFB3261E)

// 深色模式：交互蓝提亮到 DESIGN.md 里约定的 #5B9BD5，其余按同一套明度关系重排
private val DarkPrimary = Color(0xFF5B9BD5)
private val DarkBackground = Color(0xFF121417)
private val DarkSurface = Color(0xFF1B1E22)
private val DarkInk = Color(0xFFE8EAED)
private val DarkSecondary = Color(0xFFA2A9B0)
private val DarkLine = Color(0xFF2C3136)
private val DarkSuccess = Color(0xFF6FBF95)
private val DarkWarning = Color(0xFFE0A85C)
private val DarkError = Color(0xFFF2B8B5)

val LightColors = lightColorScheme(
        primary = Primary,
        onPrimary = SurfaceLight,
        primaryContainer = PrimaryDeep,
        onPrimaryContainer = SurfaceLight,
        background = Neutral,
        onBackground = Ink,
        surface = SurfaceLight,
        onSurface = Ink,
        surfaceVariant = Neutral,
        onSurfaceVariant = Secondary,
        outline = Line,
        error = Error,
        onError = SurfaceLight,
)

val DarkColors = darkColorScheme(
        primary = DarkPrimary,
        onPrimary = DarkBackground,
        primaryContainer = DarkPrimary,
        onPrimaryContainer = DarkBackground,
        background = DarkBackground,
        onBackground = DarkInk,
        surface = DarkSurface,
        onSurface = DarkInk,
        surfaceVariant = DarkSurface,
        onSurfaceVariant = DarkSecondary,
        outline = DarkLine,
        error = DarkError,
        onError = DarkBackground,
)

/** DESIGN.md 说字体一律用系统默认字体，所以这里不打包任何字体资源。 */
private val Font = FontFamily.Default

private val AppTypography = Typography(
        headlineSmall = TextStyle(fontFamily = Font, fontSize = 24.sp,
                fontWeight = FontWeight.W600, lineHeight = 1.3.em),
        titleMedium = TextStyle(fontFamily = Font, fontSize = 16.sp,
                fontWeight = FontWeight.W600, lineHeight = 1.4.em),
        titleSmall = TextStyle(fontFamily = Font, fontSize = 14.sp,
                fontWeight = FontWeight.W600, lineHeight = 1.4.em),
        bodyLarge = TextStyle(fontFamily = Font, fontSize = 16.sp,
                fontWeight = FontWeight.W400, lineHeight = 1.5.em),
        bodyMedium = TextStyle(fontFamily = Font, fontSize = 14.sp,
                fontWeight = FontWeight.W400, lineHeight = 1.5.em),
        bodySmall = TextStyle(fontFamily = Font, fontSize = 12.sp,
                fontWeight = FontWeight.W400, lineHeight = 1.5.em),
        labelLarge = TextStyle(fontFamily = Font, fontSize = 14.sp,
                fontWeight = FontWeight.W500, lineHeight = 1.2.em),
        labelMedium = TextStyle(fontFamily = Font, fontSize = 12.sp,
                fontWeight = FontWeight.W500, lineHeight = 1.2.em),
        labelSmall = TextStyle(fontFamily = Font, fontSize = 11.sp,
                fontWeight = FontWeight.W500, lineHeight = 1.2.em),
)

private val AppShapes = Shapes(
        extraSmall = RoundedCornerShape(4.dp),
        small = RoundedCornerShape(8.dp),
        medium = RoundedCornerShape(12.dp),
        large = RoundedCornerShape(16.dp),
        extraLarge = RoundedCornerShape(24.dp),
)

/** 语义色不在 Material 的颜色角色里，单独取。 */
object AppColors {
    val success: Color
        @Composable get() = if (isSystemInDarkTheme()) DarkSuccess else Success

    val warning: Color
        @Composable get() = if (isSystemInDarkTheme()) DarkWarning else Warning
}

@Composable
fun AppTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(
            colorScheme = if (dark) DarkColors else LightColors,
            typography = AppTypography,
            shapes = AppShapes,
            content = content,
    )
}
