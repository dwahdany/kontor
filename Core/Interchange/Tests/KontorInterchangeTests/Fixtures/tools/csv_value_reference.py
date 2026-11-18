"""Independent reference for CSVValueParser: random numbers and dates in the notations found in
broker exports, with expected values computed by Python's decimal and datetime modules.

Regenerate with:  python3 tools/csv_value_reference.py csv_value_reference.json
"""
import datetime
import json
import random
import sys
from decimal import Decimal, ROUND_HALF_UP

random.seed(5)


def group(integer, separator):
    out = ''
    while len(integer) > 3:
        out = separator + integer[-3:] + out
        integer = integer[:-3]
    return integer + out


numbers = []
while len(numbers) < 500:
    integer = str(random.randint(0, 10 ** random.randint(1, 9)))
    fraction = ''.join(random.choice('0123456789') for _ in range(random.randint(0, 10)))
    negative = random.random() < 0.3
    value = Decimal(integer + ('.' + fraction if fraction else ''))
    digits = random.choice([0, 2, 8])
    expected = int(value.quantize(Decimal(1).scaleb(-digits), rounding=ROUND_HALF_UP).scaleb(digits))  # half away from zero
    if negative:
        expected = -expected
    style = random.choice(['plain', 'de', 'us', 'ch', 'space'])
    separator = '.'
    if style == 'plain':
        text = integer + ('.' + fraction if fraction else '')
    elif style == 'de':
        text, separator = group(integer, '.') + (',' + fraction if fraction else ''), ','
    elif style == 'us':
        text = group(integer, ',') + ('.' + fraction if fraction else '')
    elif style == 'ch':
        text = group(integer, "'") + ('.' + fraction if fraction else '')
    else:
        text, separator = group(integer, ' ') + (',' + fraction if fraction else ''), ','
    text = random.choice(['{}', '{} EUR', '€ {}', '{} €', '${}', '{}%', 'USD {}']).format(text)
    text = (random.choice(['-{}', '{}-', '({})', '−{}']) if negative else random.choice(['{}', '+{}'])).format(text)
    numbers.append({'text': text, 'decimalSeparator': separator, 'digits': digits, 'expected': expected})

dates = []
while len(dates) < 300:
    day = datetime.date(1990, 1, 1) + datetime.timedelta(days=random.randint(0, 20000))
    hour, minute = random.randint(0, 23), random.randint(0, 59)
    order = random.choice(['yearMonthDay', 'dayMonthYear', 'monthDayYear'])
    s = random.choice(['.', '/', '-'])
    if order == 'yearMonthDay':
        text = f"{day.year:04d}{s}{day.month:02d}{s}{day.day:02d}"
    elif order == 'dayMonthYear':
        text = random.choice([f"{day.day:02d}{s}{day.month:02d}{s}{day.year:04d}", f"{day.day}{s}{day.month}{s}{day.year:04d}",
                              f"{day.day:02d}{s}{day.month:02d}{s}{day.year % 100:02d}"])
    else:
        text = random.choice([f"{day.month:02d}{s}{day.day:02d}{s}{day.year:04d}", f"{day.month}{s}{day.day}{s}{day.year % 100:02d}"])
    minute_of_day = None
    if random.random() < 0.4:
        text += random.choice([f" {hour:02d}:{minute:02d}", f" {hour:02d}:{minute:02d}:17", f"T{hour:02d}:{minute:02d}:00"])
        minute_of_day = hour * 60 + minute or None  # midnight means "no time"
    dates.append({'text': text, 'order': order, 'day': day.isoformat(), 'minuteOfDay': minute_of_day})

json.dump({'numbers': numbers, 'dates': dates}, open(sys.argv[1], 'w'), indent=0, ensure_ascii=False)
