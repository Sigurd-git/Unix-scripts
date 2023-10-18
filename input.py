import pyautogui
import pyperclip
import time
from pynput import keyboard

def type_clipboard_content():
    # 获取剪切板内容
    clipboard_content = pyperclip.paste()

    time.sleep(0.5)
    # 使用 pyautogui 模拟键盘输入
    print(clipboard_content)
    for char in clipboard_content:
        pyautogui.write(char, interval=0.001)

with keyboard.GlobalHotKeys({
        '<shift>+<ctrl>+v': type_clipboard_content}) as h:
    h.join()

