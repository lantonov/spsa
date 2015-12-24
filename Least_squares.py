import random
from chess import uci
from chess import Board
import subprocess
import platform
import numpy as np

IS_WINDOWS = 'windows' in platform.system().lower()


class RandomWalking:
    base_file_name = ''
    modified_file_name = ''
    FEN_file = "book.epd"  # a text file that contains FENs (middle game or endgame).
    # for clarity
    base_engine = None
    modified_engine = None
    info_handler_modified = None
    variables_count = 0
    variable_names = []
    best_values = []
    range = []  # [[min0,max0], [min1, max1], ...]

    def __init__(self):
        if IS_WINDOWS:
            self.base_file_name = 'base.exe'
            self.modified_file_name = 'stockfish.exe'
        else:
            self.base_file_name = './base'
            self.modified_file_name = './stockfish'
        self.detect_variable_names()
        self.open_engine_process()
        self.base_engine = uci.popen_engine(self.base_file_name)
        self.info_handler_base = uci.InfoHandler()
        self.base_engine.info_handlers.append(self.info_handler_base)
        self.base_engine.setoption({'Threads': '1'})
        self.modified_engine.setoption({'Threads': '1'})
        # for base engine selected_engine is 0
        # for modified engine selected_engine is 1
        self.selected_engine = self.base_engine
        self.selected_engine_index = 0

    def detect_variable_names(self):
        try:
            result = []
            p = subprocess.Popen([self.modified_file_name, 'uci'], stdout=subprocess.PIPE, universal_newlines=True)
            p.stdout.readline()
            while True:
                line = p.stdout.readline()
                if 'id name' in line:
                    break
                result.append(line.split(','))
            # TODO: Add exception handling logic here
        finally:
            # TODO: it's assigned?
            p.kill()
        # We have all variable names now
        self.variables_count = len(result)
        for i in range(self.variables_count):
            self.variable_names.append(result[i][0])
            self.best_values.append(float(result[i][1]))
            self.range.append([int(result[i][2]), int(result[i][3])])

    def open_engine_process(self):
        self.modified_engine = uci.popen_engine(self.modified_file_name)
        self.info_handler_modified = uci.InfoHandler()
        self.modified_engine.info_handlers.append(self.info_handler_modified)

    def __del__(self):
        self.base_engine.terminate(async_callback=False)
        self.modified_engine.terminate(async_callback=False)

    def select_engine(self, num):
        if num == 0:
            self.selected_engine = self.base_engine
            self.selected_engine_index = 0
        else:
            self.selected_engine = self.modified_engine
            self.selected_engine_index = 1

    def run_engine(self, max_depth, fen, selected_engine_index):
        self.select_engine(selected_engine_index)
        self.selected_engine.setoption({'Clear': 'Hash'})
        board = Board()
        board.set_fen(fen)
        self.selected_engine.position(board)
        self.selected_engine.go(depth=max_depth, async_callback=False)
        while self.selected_engine.bestmove is None:
            pass
        if selected_engine_index == 0:
            result = self.info_handler_base.info["score"][1].cp
        else:
            result = self.info_handler_modified.info["score"][1].cp
        return result

    def find_error(self, my_fen):
        d1 = self.run_engine(max_depth=2, fen=my_fen, selected_engine_index=1)
        d_max = self.run_engine(max_depth=8, fen=my_fen, selected_engine_index=0)
        # if you use depth 1 for both engines the values should converge to current values.
        return abs(d_max - d1)

    def mse(self, max_samples):
        p = open(self.FEN_file)
        s = 0.0
        count = 0
        line = p.readline()
        max_samples *= 1.0
        while line != '' and count < max_samples:
            s += self.find_error(line)
            count += 1
            line = p.readline()
        p.close()
        return s

    def tune(self, max_samples, max_iterations):
        values = []
        values_mean = np.mean(self.best_values)
        values_std = np.std(self.best_values)

        for i in range(self.variables_count):
            values.append(0.0)

        p = open('result.txt', 'a+')
        p.writelines('\n------------New session started-----------------\n')
        for i in range(self.variables_count):
            self.modified_engine.setoption({self.variable_names[i]: self.best_values[i]})
        self.modified_engine.ucinewgame(async_callback=False)
        min_error = error = self.mse(max_samples)
        p.writelines('Error: ' + error.__repr__() + '\n---------------------------------------\n')
        print('Error: ' + error.__repr__())

        error_vector = []
        value_vector = []
        for epoch in range(max_iterations):
            print('Epoch:' + epoch.__repr__())
            for i in range(self.variables_count):
                values[i] = random.gauss(values_mean, values_std)
                self.modified_engine.setoption({self.variable_names[i]: int(values[i])})
            self.modified_engine.ucinewgame(async_callback=False)
            error = self.mse(max_samples)

            print('Error: ' + error.__repr__())
            if error == 0:
                break

            error_vector.append(float(error))
            value_vector.extend(values)
        p.close()

        error_array = np.array(error_vector)
        value_array = np.array(value_vector).reshape(max_iterations, self.variables_count)
        beta_hat = np.linalg.inv(value_array.transpose().dot(value_array)).dot(value_array.transpose().dot(error_array))
        print(np.repeat(np.mean(error_array), self.variables_count) / beta_hat)

def main():
    rw = RandomWalking()
    rw.tune(1000, 50)

main()
