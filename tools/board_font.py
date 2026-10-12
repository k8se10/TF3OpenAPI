"""The dot font of the departure boards: 7 dots high, letters of their own width.

Each character is given as five columns of the classic 5 x 7 dot-matrix lettering (one byte a column, the
lowest bit at the top). Empty columns at a character's sides are dropped when a line is set, so that an "i"
takes less room than an "m", as on a real board. The same table is written out for the native layer by
tools/build_boards.py, so that the picture a board ships with and what is drawn live use one font.
"""

HEIGHT = 7
GAP = 1          # dark columns between two characters
SPACE = 3        # columns of a space

_TABLE = {
    ' ': '0000000000', '!': '00005F0000', '"': '0007000700', '#': '147F147F14', '$': '242A7F2A12',
    '%': '2313086462', '&': '3649552250', "'": '0005030000', '(': '001C224100', ')': '0041221C00',
    '*': '14083E0814', '+': '08083E0808', ',': '0050300000', '-': '0808080808', '.': '0060600000',
    '/': '2010080402', '0': '3E5149453E', '1': '00427F4000', '2': '4261514946', '3': '2141454B31',
    '4': '1814127F10', '5': '2745454539', '6': '3C4A494930', '7': '0171090503', '8': '3649494936',
    '9': '064949291E', ':': '0036360000', ';': '0056360000', '<': '0814224100', '=': '1414141414',
    '>': '0041221408', '?': '0201510906', '@': '324979413E', 'A': '7E1111117E', 'B': '7F49494936',
    'C': '3E41414122', 'D': '7F4141221C', 'E': '7F49494941', 'F': '7F09090901', 'G': '3E4149497A',
    'H': '7F0808087F', 'I': '00417F4100', 'J': '2040413F01', 'K': '7F08142241', 'L': '7F40404040',
    'M': '7F020C027F', 'N': '7F0408107F', 'O': '3E4141413E', 'P': '7F09090906', 'Q': '3E4151215E',
    'R': '7F09192946', 'S': '4649494931', 'T': '01017F0101', 'U': '3F4040403F', 'V': '1F2040201F',
    'W': '3F4038403F', 'X': '6314081463', 'Y': '0708700807', 'Z': '6151494543', '[': '007F414100',
    '\\': '0204081020', ']': '0041417F00', '^': '0402010204', '_': '4040404040', '`': '0001020400',
    'a': '2054545478', 'b': '7F48444438', 'c': '3844444420', 'd': '384444487F', 'e': '3854545418',
    'f': '087E090102', 'g': '0C5252523E', 'h': '7F08040478', 'i': '00447D4000', 'j': '2040443D00',
    'k': '7F10284400', 'l': '00417F4000', 'm': '7C04180478', 'n': '7C08040478', 'o': '3844444438',
    'p': '7C14141408', 'q': '081414187C', 'r': '7C08040408', 's': '4854545420', 't': '043F444020',
    'u': '3C4040207C', 'v': '1C2040201C', 'w': '3C4030403C', 'x': '4428102844', 'y': '0C5050503C',
    'z': '4464544C44', '{': '0008364100', '|': '00007F0000', '}': '0041360800', '~': '1008081008',
}


def columns(character):
    """The lit columns of one character, its empty sides dropped (a space: SPACE empty columns)."""
    if character == ' ':
        return [0] * SPACE
    text = _TABLE.get(character, _TABLE['?'])
    cols = [int(text[i:i + 2], 16) for i in range(0, 10, 2)]
    while cols and cols[0] == 0:
        cols.pop(0)
    while cols and cols[-1] == 0:
        cols.pop()
    return cols or [0]


def line(text):
    """A line of text as a list of columns (each a 7-bit number, lowest bit at the top)."""
    out = []
    for index, character in enumerate(text):
        if index > 0:
            out.extend([0] * GAP)
        out.extend(columns(character))
    return out


def characters():
    return sorted(_TABLE)
