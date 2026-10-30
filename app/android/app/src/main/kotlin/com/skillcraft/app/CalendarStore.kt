package com.skillcraft.app

import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Instances
import java.util.TimeZone

/**
 * The device calendar through CalendarContract, for the calendar tool server.
 * Times are epoch milliseconds; callers hold READ/WRITE_CALENDAR and call
 * these off the main thread.
 */
class CalendarStore(private val resolver: ContentResolver) {

    /** Adds an event to the primary writable calendar; returns its id. */
    fun insert(title: String, startMs: Long, endMs: Long, description: String?): Long {
        val values = ContentValues().apply {
            put(Events.CALENDAR_ID, writableCalendarId())
            put(Events.TITLE, title)
            put(Events.DTSTART, startMs)
            put(Events.DTEND, endMs)
            put(Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
            if (description != null) put(Events.DESCRIPTION, description)
        }
        val uri = resolver.insert(Events.CONTENT_URI, values)
            ?: throw IllegalStateException("The calendar did not accept the event")
        return ContentUris.parseId(uri)
    }

    /** Event occurrences overlapping [fromMs, toMs), recurring ones expanded. */
    fun list(fromMs: Long, toMs: Long): List<Map<String, Any?>> {
        val projection = arrayOf(
            Instances.EVENT_ID, Instances.TITLE, Instances.BEGIN, Instances.END,
            Instances.ALL_DAY, Instances.CALENDAR_DISPLAY_NAME,
        )
        val events = mutableListOf<Map<String, Any?>>()
        Instances.query(resolver, projection, fromMs, toMs)?.use { c ->
            while (c.moveToNext()) {
                events += mapOf(
                    "id" to c.getLong(0).toString(),
                    "title" to c.getString(1),
                    "start" to c.getLong(2),
                    "end" to c.getLong(3),
                    "allDay" to (c.getInt(4) == 1),
                    "calendar" to c.getString(5),
                )
            }
        }
        return events.sortedBy { it["start"] as Long }
    }

    /** Removes an event (used by tests to clean up; not a tool). */
    fun delete(eventId: Long): Boolean =
        resolver.delete(ContentUris.withAppendedId(Events.CONTENT_URI, eventId), null, null) > 0

    /** The primary calendar the user can write to, else the first writable one. */
    private fun writableCalendarId(): Long {
        val projection = arrayOf(Calendars._ID, Calendars.IS_PRIMARY)
        val selection = "${Calendars.CALENDAR_ACCESS_LEVEL} >= ? AND ${Calendars.VISIBLE} = 1"
        val args = arrayOf(Calendars.CAL_ACCESS_CONTRIBUTOR.toString())
        var first: Long? = null
        resolver.query(Calendars.CONTENT_URI, projection, selection, args, null)?.use { c ->
            while (c.moveToNext()) {
                if (c.getInt(1) == 1) return c.getLong(0)
                if (first == null) first = c.getLong(0)
            }
        }
        return first ?: throw IllegalStateException("No writable calendar on this device")
    }

    companion object {
        val PERMISSIONS = arrayOf(
            android.Manifest.permission.READ_CALENDAR,
            android.Manifest.permission.WRITE_CALENDAR,
        )
    }
}
